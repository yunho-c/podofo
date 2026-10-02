# Development and verification

The Flutter application is in `podofo_frontend_one`. Use Flutter **3.47.5** /
Dart **3.13.4**. FVM is optional if that SDK is already on PATH. Windows builds
need Visual Studio's Desktop development with C++ workload and the Windows SDK.
No sibling repositories are required.

From the application directory:

```powershell
flutter pub get --enforce-lockfile
./tool/verify.ps1
```

To use an SDK that is not on PATH:

```powershell
./tool/verify.ps1 -Flutter C:/path/to/flutter/bin/flutter.bat -Dart C:/path/to/flutter/bin/dart.bat
```

The script checks formatting and deterministic ObjectBox generation, analyzes
the app, builds Windows Release, and tests against the bundled native database
library. Its checks also run in GitHub Actions. Do not skip the native tests:
they caught a real ARM64 DLL accidentally packaged into an x64 build.

For a focused test after a build:

```powershell
$env:PATH = (Resolve-Path build/windows/x64/runner/Release).Path + ';' + $env:PATH
flutter test test/native_regression_test.dart --no-pub --reporter expanded
```

The generated PDF test fixture is local, small, and includes normal, cropped,
and rotated pages. No remote PDFs or user databases are used by the tests.

## Windows plugin links

If the account lacks symbolic-link privileges, `pub get` may resolve packages
then stop at Flutter's plugin-link step. This optional fallback creates only
junctions in the project's ignored platform directories:

```powershell
./tool/prepare_windows_plugins.ps1
flutter pub get --enforce-lockfile
```

Repeat after `flutter clean` or plugin updates. The helper checks existing links
and updates package destinations without changing Windows settings, the SDK,
or the package cache.

## Model changes

Keep `lib/objectbox-model.json` in Git. Renames must preserve UIDs explicitly.
Never remove a user's database to work around schema errors.

`test/fixtures/legacy_objectbox_model.json` captures the original schema.
`legacy_objectbox.g.dart` preserves its old serialization layout; imports and
the generator-version marker are adapted to the current runtime. Native tests
create a legacy database and open it using the regenerated model.

After an intentional model edit:

```powershell
dart run build_runner build
dart format lib test
./tool/verify.ps1
```

ObjectBox 5.3.2 requires analyzer <11. Keep build_runner pinned to 2.15.1 until
a compatible ObjectBox generator supports the newer analyzer; do not override
the analyzer constraint merely to silence an SDK language-version warning.

## Reader controls

- Ctrl/Command+O opens a PDF; Ctrl/Command+P opens recent files.
- Ctrl/Command+F searches; Ctrl/Command+B opens thumbnails.
- The highlighter toggles highlighting mode. Right-click or long-press it for
  colors; a selection-menu swatch highlights text directly.
- Ctrl/Command+Shift+H highlights selected text.
- Ctrl/Command+S saves; Ctrl/Command+Shift+S saves to another path.
- Ctrl/Command+W closes the tab; Ctrl/Command+Q requests a safe quit.
- Ctrl+Tab / Ctrl+Shift+Tab switches tabs; Ctrl/Command+1–9 selects a tab and
  Ctrl/Command+0 selects the last tab.
- The More menu controls auto-save.
- Right-click blank space in a PDF page or the surrounding viewer pane, then
  use the **View** section: **Two pages** for side-by-side spreads, or
  **Single page** for the standard layout. Right-clicking text offers text
  actions without the View section. Spreads pair pages 1–2, 3–4, etc.; an
  unpaired last page is centered. Switching fits the current page or spread into
  the viewer. Each open tab remembers its layout until it is closed.
- PDF context menus open at the pointer, shifting only as needed to stay visible
  at the edges of the pane (in-document) or window (surrounding padding).
  Their theme and highlight swatches are unaffected by PDF color inversion.
- The Annotations pane lists and removes existing highlights.

Bare letter/number hotkeys no longer intercept typing in text fields.
Disabled controls identify features that are not available yet.

See [modernization.md](modernization.md) for design decisions and limitations.
