# Material Regression Table — session 4.2

This is the agreed name for the UI origin table discussed during the session.
The baseline before stabilization is commit `9594008`; stabilization began with
`7a7507d`. Some existing controls were placeholders whose behavior was completed.
The Windows/Linux File menu already used Material components before stabilization.

| Control / functionality | Before stabilization | Introduced during stabilization |
| --- | --- | --- |
| File → Open | Working File menu; Material on Windows/Linux, native on macOS | Replacement menu implementation and additional actions |
| Save / Save As | macOS entries incorrectly opened the file picker | Actual PDF saving and working entries on Windows/Linux and in More |
| Save / Discard / Cancel dialog | Absent | Unsaved-change protection |
| Replace existing PDF dialog | Absent | Overwrite confirmation |
| Close tab | Tab buttons and Ctrl+W worked | Unsaved-change handling and a File-menu entry |
| Auto-save | Shadcn switch stored its preference | Actual automatic PDF saving |
| Annotations pane | Sidebar entry with placeholder content | Listing, navigation, and removal of actual highlights |
| Recovery notices | Absent | Retry, Remove from session, and Dismiss controls |
| Hotkeys / shortcut dialog | Menu entry opened a Shadcn demo profile form | Actual shortcut help in a Material dialog |
| Highlighter, palette, custom color picker | Shadcn and ordinary Flutter controls; mode and color settings worked | Persistent annotations and rewritten controls; compact presentation subsequently restored |
| Selection-menu highlighting | Menu and swatches changed the selected color | Applying actual PDF highlights |
| Sidebar/highlighter/audio tooltips | Tooltip wrappers absent | Added during stabilization and follow-up adjustments |
| Undo last highlight | macOS had a nonfunctional generic Undo entry | Working highlight-batch undo; its new menu entry was subsequently removed |
| Windows minimize/maximize/close controls | Absent from the custom title bar | Window-caption buttons |
| Recent-files title-bar control | Blank pill-shaped control opened recent files | Changed appearance and label |

## Restoration status

- Recent-files title-bar control: restored the original unlabeled 200 × 15 pill,
  accent color, and 5-pixel corner radius. Clicking it still toggles recent files.
  Its accessible name remains “Recent files.”
