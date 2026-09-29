# Validation record

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

## Non-blocking upstream warnings

ObjectBox's generator uses an analyzer supporting Dart 3.12 language features;
the application SDK is Dart 3.13. The compatible generator/build_runner versions
are intentionally pinned. Generation and the native migration tests are the
acceptance checks; no incompatible analyzer override is used.

ObjectBox's Windows CMake currently uses the deprecated
`FetchContent_Populate` API. Its CMake development warning does not indicate a
failed build. Revisit both compatibility pins and this upstream warning when
updating ObjectBox.
