# Validation record

## Context-menu integration with MLSR main — 2026-10-24

Merged main at `3b94d13` into `fix/context-menu`, retaining the two-page layout,
pointer-anchored menus, and menu rendering outside PDF inversion alongside the
narration and citation-back callbacks. Initial spread fitting precedes narration
viewport tracking, and changing layout cancels an active citation transition.

This integration uses published pdfrx 2.6.5 and pdfrx_engine 0.6.1. It does not
include the pending dependency backports, internal-link-preview branch, or
Windows-titlebar branch.

- Locked dependency resolution passed without changing `pubspec.lock`.
- Static analysis and formatting checks passed.
- **12 focused tests passed** across `pdf_page_layout_test.dart`,
  `pdf_context_menu_overlay_test.dart`, `two_page_view_test.dart`,
  `reader_navigation_test.dart`, and `reader_widget_test.dart`.
- Added real-PDF coverage for switching to two pages during fake narration,
  right-page citation navigation, and page-relative Back after changing layout.
  Existing checks cover menu placement/color isolation, selection/tab retention,
  highlight/save behavior, keyboard access, reduced motion, and touch Back.
- Three original navigation tests also failed against unmodified main with the
  published dependency: they assumed immediate link-tap dispatch. The helper now
  waits for navigation history to record the tap before checking the animation,
  accommodating pdfrx's double-tap timeout without changing library behavior.
- `bash tool/build_macos_local.sh debug` produced a locally signed Apple Silicon
  app; deep/strict signature verification passed. Native tests used ObjectBox and
  PDFium from this Debug bundle via `DYLD_LIBRARY_PATH` and `PDFIUM_PATH`, with
  Flutter's Dart tool snapshot invoked directly.

Logs are in `podofo_frontend_one/build/context-menu-*.log` in the integration
worktree. The full suite, real audio playback, and native GUI acceptance were
not rerun; the Debug bundle is prepared for manual testing. Existing plugin,
deprecation, bundle-identifier, and toolchain-path build diagnostics remain.

## Internal-link return navigation — 2026-10-22

Restored the original outlined back arrow, 60px hover region, 10px inset, and
100ms fade. The icon now returns through a bounded history owned by each open
document, restoring the reading position and zoom. No dependency updates were
needed for this change.

- `flutter analyze --no-pub`: no issues.
- `python3 tool/test_macos.py` in the working checkout: **174 passed, 4 skipped**.
  This includes the existing local pdfrx backport. The skipped tests are
  the opt-in native MLSR audio/corpus tests; narration-follow behavior here uses
  the fake playback backend.
- Five new test cases cover real PDF citation clicks, nested and same-page
  returns, hover/focus, zoom/resize, tab isolation, Save As, interrupted
  navigation, close/reopen, invalid destinations, keyboard activation, reduced
  motion, and Android/iOS touch presentation in the widget runner.
- `bash tool/build_macos_local.sh release`: Apple Silicon Release build and
  local signature verification passed. Existing plugin/deprecation, bundle-ID,
  and toolchain-path warnings remain unrelated to this feature.

The widget-rendered hover image is in
`podofo_frontend_one/build/test-artifacts/citation-back-hover.png`. Test, analysis,
and build logs are in `podofo_frontend_one/build/link-back-*.log`. Native window
interaction was not manually exercised for this change. The old source/archive
and `podofo-comparison/PoDoFo Old.app` were left untouched.

## Earlier Windows verification

Environment: Windows on ARM64, Flutter 3.47.5 / Dart 3.13.4, Visual Studio
Build Tools 2022. The application and Flutter test engine target x64.

## Final verification

- Locked package resolution: passed with `flutter pub get --enforce-lockfile`.
- Formatting: 60 Dart files checked, no changes.
- Code generation: repeat build_runner run wrote zero outputs; the model and
  generated bindings were unchanged after canonical formatting.
- Static analysis: no issues.
- Windows x64 release build: passed (51.2 seconds on the final build).
- Complete regression suite: **15 tests passed**, using the release bundle's
  ObjectBox DLL. The reader test waits for native rendering work instead of
  advancing Flutter's simulated clock while thumbnail jobs are pending.
- PowerShell verification script: syntax checked; CMake stderr warnings are
  displayed without overriding its actual process exit code.

The final checks were run on 2026-09-29. Local command logs remain in the ignored
application directory: `locked-resolution.log`, `verification.log`,
`final-analysis.log`, and `final-tests.log`.

The native tests use the same ObjectBox version and architecture as the
application. PE inspection confirms `PoDoFo.exe`, `objectbox.dll`, and
`pdfium.dll` are x64 (machine 8664), correcting the original ARM64/x64 mismatch.

## Scope of evidence

The regression suite uses a hand-authored three-page PDF and temporary
databases/files. It does not modify real user PDFs or the installed user database.
It exercises the actual PDFium rendering/editing/saving backend and actual
ObjectBox storage, alongside lifecycle unit tests and reader widget tests.

The rendered cropped-page fixture was inspected: the highlight covers “Hello”
and aligns with its glyphs. Tests check native attachment coordinates for both
cropped and rotated pages. The suite writes the inspected rendering to
`podofo_frontend_one/build/test-artifacts/annotated-cropped.png`.

The GitHub Actions workflow is added but has not been run remotely: no push or
publication is part of this local change. macOS/Linux release builds and native
file-picker/window-manager interaction on those systems remain unverified.
The widget tests exercise shared save/close logic; they do not drive operating
system file dialogs or native window-close events.

## Highlighting UI restoration follow-up

The compact highlighter palette and selection menu were restored with the current
PDF backend. The expanded reader test checks the right-click palette, inline
custom-color persistence, mode toggling, deferred application during a paused
selection gesture, and direct application from a selection-menu swatch before
exercising saving and closing.

All 15 regressions pass, static analysis reports no issues, and the Windows x64
release rebuild passed (112.7 seconds). Logs are `highlight-ui-analysis.log`,
`highlight-ui-tests.log`, and `highlight-ui-build.log`. Widget captures in
`build/test-artifacts/highlight-*.png` were checked for palette and picker layout;
the test engine uses fallback glyphs for some application text and icons.

## Empty highlight selection follow-up

Highlight requests now ignore selections without drawable text bounds and keep
valid fragments when a selection crosses empty pages or separator glyphs.
Three selection-conversion regressions cover mixed and empty geometry and
text-copy restrictions. The real-reader test also checks that toggling the mode
and invoking the shortcut without a selection leave the document clean and show
no error.

All 18 regressions pass, static analysis reports no issues, and the Windows x64
release build passed (82.9 seconds). Logs are `highlight-selection-tests.log`,
`highlight-selection-analysis.log`, and `highlight-selection-build.log`.

## Thumbnail presentation restoration

All 19 regressions pass with Impeller enabled, including the restored thumbnail
shader, keyboard focus navigation, and preservation of thumbnail scroll position
and viewer page across theme changes. Native tests also check distinct cache
entries for different display resolutions and bounded raster dimensions. Static
analysis reports no issues. Logs are `thumbnail-tests.log` and
`thumbnail-analysis.log`.

The Windows x64 release build passed (140.8 seconds); its log is
`thumbnail-build.log`.

The light/dark captures in `build/test-artifacts/thumbnails-*.png` were inspected:
cards use the original proportions and spacing, visible page captions are absent,
and the dark preview images use the original inversion effect. The test renderer
still uses fallback glyphs for some unrelated UI text/icons.

## Page-based thumbnail sizing

The focused reader regression passes with Impeller enabled and confirms that
landscape cards are shorter than portrait cards at the same width. Light/dark
captures were inspected after image decoding completed. Static analysis reports
no issues, and the Windows x64 release build passed (144.9 seconds). Logs are
`thumbnail-sizing-tests.log`, `thumbnail-sizing-analysis.log`, and
`thumbnail-sizing-build.log`.

## Non-blocking upstream warnings

ObjectBox's generator uses an analyzer supporting Dart 3.12 language features;
the application SDK is Dart 3.13. The compatible generator/build_runner versions
are intentionally pinned. Generation and the native migration tests are the
acceptance checks; no incompatible analyzer override is used.

ObjectBox's Windows CMake currently uses the deprecated
`FetchContent_Populate` API. Its CMake development warning does not indicate a
failed build. Revisit both compatibility pins and this upstream warning when
updating ObjectBox.
