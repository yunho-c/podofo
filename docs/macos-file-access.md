# Persistent macOS document access

PoDoFo keeps App Sandbox enabled. A saved pathname cannot restore the permission
granted by the file picker after quitting. The macOS runner now stores read/write,
app-scoped security bookmarks in native preferences
(`podofo.securityScopedBookmarks.v1`). Debug/Profile and Release both enable
`com.apple.security.files.bookmarks.app-scope`. ObjectBox schemas are unchanged.

`DocumentFileAccess` calls `FileAccessStore` before reads and saves. It resolves
bookmarks without prompting, starts access, refreshes stale bookmarks, and returns
the resolved path and a lease token. Dart releases access in `finally`. PDFium uses
detached bytes; rendering and narration do not hold file grants. Other platforms
continue using their ordinary filesystem permissions.

Selected and canonical paths share bookmarks. Resolved moves update the opened
path and session record. Aliases are refreshed together. Bookmarks remain after a
tab closes so the recent-document list can also reopen files.

## Recovery and saves

Legacy records have no bookmarks. If the path is inaccessible, the record remains
in the session. **Locate PDF…** opens the system picker, remembers the grant, and
restores the saved page, clamped to the selected PDF. Cancellation or a failed open
does not discard the original record. Retry repeats the read without prompting.
Expired bookmarks, including after signing-identity changes in development, can
also be recovered by selecting the file again.

Normal saves reacquire access. Save As uses the explicitly selected destination
rather than following an older bookmark for that pathname. Foundation supplies
an item-replacement staging directory on the target volume; permission for one
PDF does not authorize arbitrary temporary siblings. Conflict checks, PDF
validation, and atomic rename continue protecting the destination.

After replacement or Save As, the bookmark is refreshed. If refreshing fails,
the committed PDF remains saved and clean; the UI reports that permission may
need granting again next launch.

## Validation

From `podofo_frontend_one`:

```sh
../.fvm/flutter_sdk/bin/flutter analyze
python3 tool/test_macos.py
bash tool/build_macos_local.sh debug
```

The unit/widget runner supplies a filesystem-only method-channel double because
it does not load Runner plugins. Production has no silent MissingPlugin fallback.
Tests cover moved paths, explicit selections, failed opens, release, save conflicts,
Save As, bookmark-refresh warnings, and legacy recovery through a symlink. The
notice widget test checks recovery targeting and narrow-window layout. These
checks do not prove sandbox persistence across launches.

A native Foundation regression also checks that selecting a new document at a
moved document's old path does not redirect the moved document's bookmark:

```sh
xcrun swiftc macos/Runner/FileAccessStore.swift tool/macos_file_access_store_test.swift \
  -o /tmp/podofo-file-access-store-test
/tmp/podofo-file-access-store-test
```

### Native sandbox probe

Compile `tool/macos_file_access_probe.swift` together with production
`macos/Runner/FileAccessStore.swift` into a disposable `.app`. Give it a unique
bundle ID and Info.plist naming its executable, then sign it with the Release
sandbox entitlements. Example commands from `podofo_frontend_one`:

```sh
xcrun swiftc macos/Runner/FileAccessStore.swift tool/macos_file_access_probe.swift \
  -o /path/to/FileAccessProbe.app/Contents/MacOS/FileAccessProbe
codesign --force --sign - --entitlements macos/Runner/Release.entitlements \
  /path/to/FileAccessProbe.app
open -n /path/to/FileAccessProbe.app --args --grant /absolute/path/to/fixture.pdf
```

Create the disposable fixture outside the probe container, containing exactly
`persistent-access-before-save` followed by a newline. Select it in the picker.
The probe refuses to modify another path or contents. It reads, stages, atomically
replaces, refreshes the bookmark, and exits. Results are in `probe-result.json`
under `~/Library/Containers/<bundle-id>/Data/`.

Copy the result, then launch the same signed probe without arguments. Require
`success: true`, `deniedBeforeRestore: true`, `scopeStarted: true`, and
`restoredRead: "persistent-access-after-save\n"`. This distinguishes restored
permission from a path that was already readable. Move only the fixture while
the probe is stopped, relaunch, and check the resolved path and unchanged contents.
Relaunch once more to check persistence of the refreshed bookmark.

Separately check the real app: recover a legacy entry, verify its last page, quit
fully, relaunch, save an annotation, and relaunch again. Record native probe,
widget-test, and real-app observations separately.

## Verification on 2026-10-21

- Static analysis: no issues.
- Standard suite: 139 passed, 3 opt-in tests skipped.
- macOS Debug build and nested signature verification passed; its signed
  entitlements include app sandbox, user-selected read/write, and app-scoped bookmarks.
- Native sandbox probe: initial direct read denied; picker grant, read, atomic
  replacement, and bookmark refresh succeeded. A fresh process denied direct
  access and then read successfully after restoring the bookmark. Moving the
  fixture and launching twice more resolved the new path with the same contents.
- Native alias regression passed. The sandbox probe also restored successfully
  after rebuilding with the alias guard.

Probe evidence is in the ignored `ignore/macos-file-access-probe/` directory.
Build and suite logs are in `podofo_frontend_one/build/macos-file-access-*.log`.
The probe uses production native code. The user subsequently confirmed that the
fix works in PoDoFo. The agent did not independently exercise the full Flutter
quit/relaunch and annotation-save sequence with a user document.
