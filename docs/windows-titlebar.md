# Windows title bar behavior

The stabilization title bar used `window_manager`'s Flutter `WindowCaption`.
Those controls simulated Windows visuals and actions, but did not expose native
caption hit targets or accessibility. Their hover colors changed immediately.
Windows now draws and handles its own minimize, maximize/restore, and close
buttons, while Flutter continues to draw the File menu and recent-files control.

## Behavior and guidance

| Concern | Implementation |
| --- | --- |
| Hover, pressed, inactive states and animation timing | DWM owns the actual caption controls. No app animation duration is substituted. |
| Snap Layout menu on Windows 11 | Native non-client input, including `HTMAXBUTTON` over maximize/restore. |
| Accessible names, button roles, default actions and tooltips | Supplied by Windows, including the Maximize/Restore state change. |
| Light and dark app themes | Synchronize the native caption background and dark-mode attribute with Flutter. |
| High contrast | Read `SPI_GETHIGHCONTRAST`, restore the default DWM caption color, and stop forcing dark mode. Reapply on theme/settings/color changes. |
| Blank title bar gestures | Drag to move, double-click to maximize/restore, right-click for the system window menu. Interactive controls keep their ordinary clicks. |
| Close and unsaved work | Plugins receive `WM_CLOSE` first, preserving the existing Dart close guard and unsaved-change flow. |
| Scaling and maximized bounds | Reserve the actual DWM caption bounds in logical pixels and update the Flutter cutout after native layout changes. |

Microsoft's [title bar design guidance](https://learn.microsoft.com/en-us/windows/apps/design/basics/titlebar-design)
describes the required states and gestures. It does not specify one universal
hover-animation duration; native rendering follows the installed Windows theme
and animation settings. The [DWM custom-frame guidance](https://learn.microsoft.com/en-us/windows/win32/dwm/customframe)
supports retaining system caption controls in an extended frame. The
[Snap Layout guidance](https://learn.microsoft.com/en-us/windows/apps/desktop/modernize/ui/apply-snap-layout-menu)
specifies `HTMAXBUTTON` for custom Win32 frames.

The Flutter child window is clipped around the caption area, so it cannot paint
over the native buttons or intercept their pointer input. `DwmDefWindowProc`
receives non-client messages, including mouse leave. The parent retains native
resize borders and paints the transparent black backing required by DWM.
[`DWMWINDOWATTRIBUTE`](https://learn.microsoft.com/en-us/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute)
documents the caption bounds, color overrides and default-color sentinel.
Unsupported color attributes are harmless on older Windows versions.

The suspected hover-entry problem was excluded from the requested fixes. This
change does not add a separate workaround for it. Non-Windows caption handling
retains the existing platform behavior.

## Verification

From `podofo_frontend_one` on Windows 11:

```powershell
./tool/verify_windows_titlebar.ps1 -Flutter C:/path/to/flutter/bin/flutter.bat
./tool/verify.ps1 -Flutter C:/path/to/flutter/bin/flutter.bat -Dart C:/path/to/flutter/bin/dart.bat
```

The first script builds an isolated native fixture using in-memory preferences
and an empty document session; it never opens the user's PDFs or database. In
both light and dark modes it checks caption hit tests, Flutter clipping, MSAA
names/roles/states, minimize/maximize/restore actions, rendered caption colors,
and delivery of close to Dart followed by a successful exit. App-only screenshots
are written to `build/titlebar-review`. `-SkipBuild` requires an executable already
built from `tool/title_bar_smoke.dart`.

The second script restores the normal application executable and runs formatting,
code generation, analysis, the release build and regression tests. Focused widget
tests cover title bar gestures, immediate File/recent-files clicks, dynamic native
metrics and theme-channel updates.

The native verifier checks the Windows hit-test contract for Snap Layouts, not the
shell flyout itself. Hover timing, native tooltips and high-contrast appearance
are owned by Windows; the script does not change global theme, animation or
accessibility settings. For visual acceptance, compare active/inactive captions,
hover/press, Snap Layouts and tooltips with a standard Windows window under the
same settings. Check high-contrast themes and movement between monitors with
different DPI settings on the target machines. The app's existing 760-pixel
minimum width can still restrict small Snap Layout zones.
