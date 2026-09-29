# UI comparison with the pre-stabilization reader

Reviewed on 2026-09-29 against `9594008`, the last commit before stabilization.
The comparison includes the follow-up restorations through `f0b3de8`, the
proportional scrollbar change documented here, and the separate outline
restoration present in the working tree during this review. It covers application
code, current package behavior relevant to that code, and focused Windows widget
checks. It is not a pixel comparison against a rebuilt old executable.

## Scrollbar restored in this change

The vertical thumb again represents the visible fraction of the PDF. Its height
is the viewport height multiplied by the visible document fraction, with the
original 40-pixel minimum, capped at the viewport height. Width, rounded corners,
and translucent gray styling are unchanged. The calculation includes zoom and
the same finite boundary margins used by pdfrx's scrollbar; its existing behavior
hides the thumb when the document fits.

The old calculation mixed viewport pixels with unscaled document dimensions.
The restored calculation uses the visible rectangle in document coordinates,
so it also stays proportional when zoom changes. pdfrx rebuilds viewer overlays
as the viewport changes; no extra controller listeners or PDF ownership changes
are necessary.

The reader regression exercises zoom, window resizing, minimum thumb height,
restoring the original viewport, and dragging to both ends of a real PDF.

## Outstanding functional and presentation regressions

These remain after the scrollbar restoration. They are review findings, not
additional changes made by this patch.

| Area | Before stabilization | Current difference and impact | Source |
| --- | --- | --- | --- |
| Closing during startup | Native close was not intercepted | `setPreventClose(true)` runs before the close listener is mounted. The listener exists only in the successful startup branch, so loading or a startup error can leave close requests unhandled. Highest priority. | [window.dart](../podofo_frontend_one/lib/src/services/window.dart), [main.dart](../podofo_frontend_one/lib/main.dart) |
| Typography | Inherited app text used the configured Urbanist theme | The global Material wrapper installs its own default text style. The Windows widget check measured the File label at 14 px Segoe UI versus 16 px Urbanist without that wrapper; color and letter spacing change too. | [main.dart](../podofo_frontend_one/lib/main.dart) |
| Search focus and pane toggles | Clearing search requested input focus; Ctrl+F and Ctrl+B toggled their panes | Clearing search leaves input unfocused. Ctrl+F does not refocus an already-open search field. Ctrl+B cannot close thumbnails on a second press. Reproduced in the widget check. | [search_pane.dart](../podofo_frontend_one/lib/src/widgets/panes/search_pane.dart), [hotkey_provider.dart](../podofo_frontend_one/lib/src/providers/hotkey_provider.dart) |
| Window placement | Saved position was read and written | Startup always centers the window and only size is saved. Valid previous positions and monitor placement are ignored. Off-screen recovery should be conditional. | [window.dart](../podofo_frontend_one/lib/src/services/window.dart) |
| PDF link appearance | Explicit blue tint with 1% opacity | Omitted `linkColor` selects pdfrx's default blue with alpha 50/255, roughly 20%. This paints noticeable rectangles over links independently of the link-preview policy. Confirmed in a rendered fixture. | [custom_pdf_viewer.dart](../podofo_frontend_one/lib/src/widgets/components/custom_pdf_viewer.dart) |

## Additional differences to review for visual and interaction fidelity

These are concrete differences beyond the five findings above. Some are useful
additions or deliberate simplifications, but they prevent an exact return to
the earlier interface.

| Area | Outstanding difference |
| --- | --- |
| Search layout | A compact input/action row became a full-width input above a separate count/action row. Results changed from 60-pixel items grouped beneath one heading per page to 76-pixel items repeating the page label. Snippets now use a fixed character window and two-line ellipsis. The current result gains a secondary background; Next/Previous also scroll the row toward the top even when it was already visible. |
| Search timing | The app adds a 180 ms debounce before calling pdfrx, whose current default adds another 500 ms. The old UI called the searcher directly. This adds application-level delay, separate from any engine-version differences. |
| Other shortcuts | Bare H for highlight mode and digits for palette selection were removed entirely to avoid interfering with typing. Ctrl/Command+O changed from toggling the outline to opening a file, leaving no outline shortcut. The former Ctrl/Command+Shift+F shortcut for unfinished AI Search was removed along with that feature's activation. A focus-aware replacement could preserve working reader shortcuts without intercepting text fields. |
| Title bar | The original 200 x 15 recent-files control is restored, but bar height is 32 rather than 30 pixels. The File area is now a fixed 80 pixels. Added Windows/Linux caption controls occupy 138 pixels, changing the space in which the recent-files control is centered. The native title bar remains hidden. |
| File menu | A Material popup replaces the previous submenu widget, changing placement and styling. Save, Save As, and Close tab are functional additions. Print/Export are disabled. macOS now has the functional File menu instead of the old collection of mostly placeholder app/Edit/View/Window/Help menus, and also receives the in-window File control. Native macOS layout needs inspection. |
| Open-file control | The tab strip's plus icon became a folder icon. The location and open-file action remain the same. |
| Highlight palette | Compact swatches and an inline picker are restored. Swatches now have 24-pixel focusable hit targets around 16-pixel circles, a 4-pixel selected border instead of 5, and wrapping behavior. The palette/picker use explicit widths; old instructional text and inactive settings switches were removed. Long press now also opens the palette. |
| Selection menu | Copy/Select all labels are now literal English rather than Shadcn localization strings. The menu has a fixed 192-pixel width and uses pdfrx's current positioning. Highlight swatches now actually create annotations; previously they selected a color and dismissed the menu. |
| More menu | Working Save/Save As entries were added; Auto-save remains. Shortcut help replaces the fake profile editor. Inert settings/community/link items and utility submenus were removed or consolidated into disabled entries. The added Undo menu entry and explanatory copy were subsequently removed at the user's request. |
| Minimum window size | The app now enforces 760 x 520 and clamps restored sizes. It previously had no application-level minimum in this configuration. |

## Restored or intentionally retained changes

- The recent-files title-bar control is back to the original unlabeled pill.
- The separate outline restoration replaces the temporary button rows with the
  tree widget again, restoring compact single-line labels, enabled group headings,
  and keyboard expansion/navigation. Its source and test changes were already
  in progress during this review; they are not part of the scrollbar patch.
  Its navigation and styling checks pass. At review time, its third test for
  reporting a failed destination did not observe the expected error, so that
  change still needs final verification.
- The highlighter icon, highlighting mode, compact palette, and selection-menu
  swatches are restored, with actual persistent editing behind them.
- Thumbnail styling, spacing, focus navigation, dark inversion, and absence of
  visible captions are restored. Card proportions now follow the actual page,
  including cropping and rotation, rather than forcing every page to 1:1.38.
  Rendering remains lazy, bounded, and aware of display density. See
  [thumbnail-restoration.md](thumbnail-restoration.md).
- Theme/inversion changes preserve the PDF viewport. Page shadows are deliberately
  subtler than the original styling following the separate shadow adjustment.
- Tabs retain their previous sizing, hover close controls, and overall layout;
  the unsaved-change dot is a new indicator for functional editing.
- Side pane width remains 250 pixels, the document header remains 40 pixels,
  and the recent-files popup's layout and filtering are substantially unchanged.
- Persistent highlights, annotation removal, save conflict handling, unsaved-change
  prompts, and per-document recovery notices are intentional functionality added
  during stabilization. Their dialogs and notices have no equivalent working UI
  in the old reader.
- AI/study/audio/extensions and the other unfinished actions remain disabled as
  requested. Destination-only link cards and explicit HTTP/HTTPS opening remain
  the documented preview behavior; restoring the subtle link tint is independent.
- The unused floating back button and fake profile editor were removed. Neither
  had a working reader action to restore.

## Evidence and limitations

The earlier focused audit used temporary PDFs/databases and recorded typography,
search focus, pane toggling, outline expansion, link rendering, and startup
listener registration. Its scratch harness and logs are in the ignored `build/`
and application log paths. The scrollbar checks are part of the committed reader
regression rather than that scratch harness.

For this scrollbar change, static analysis passed with no issues and the complete
reader widget regression passed, including zoom, resizing, the minimum thumb
height, dragging to both ends, and the existing editing/saving workflow.
The Windows release build also passed. It emitted the existing ObjectBox CMake
deprecation warning about `FetchContent_Populate`.
The separate outline test run recorded two passes and one failure, as noted above.

No user documents or installed database were used for these checks. macOS/Linux
native windowing, platform menus, file dialogs, and system-theme transitions have
not been exercised here. Package-default styling may differ beyond the explicit
application changes listed above. The nonreactive system-theme provider already
existed before stabilization, so it is not counted as a new regression.
