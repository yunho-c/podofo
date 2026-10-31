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

## Cloud-backed PDF reads

Opening a PDF on macOS uses `FileAccessLease.read()` after acquiring the existing
bookmark lease. The native bridge uses a separate `NSFileCoordinator` and read
intent for each request, with an `OperationQueue` off the main thread. It reads
the intent's URL inside the coordinated accessor, then returns the resolved path
and detached bytes to Dart. Even symlink resolution for the open happens there;
Dart does not read or resolve the cloud placeholder first. PDFium opens the
returned bytes, and `finally` releases the grant on success or failure.

This lets File Provider download an online-only Google Drive/iCloud document
before the read. A plain Dart read can fail with `EDEADLK` (errno 11 on macOS) for
a dataless file. Wrapped POSIX `EDEADLK` and File Provider errors now produce a
cloud-sync / **Available offline** recovery message. Other read errors retain
their native description; the bridge preserves error domain/code details for
diagnostics. Missing native plugin support fails explicitly, without falling back
to an uncoordinated read. Other platforms keep the existing Dart file I/O path.

This change coordinates opening only. Save conflict checks and atomic replacement
retain their existing implementation. File coordination and sandbox authorization
are separate: coordination does not grant access or bypass an offline provider.

Apple documents [asynchronous file coordination](https://developer.apple.com/documentation/foundation/improving-performance-and-stability-when-accessing-the-file-system)
and [dataless file handling](https://developer.apple.com/documentation/technotes/tn3150-getting-ready-for-data-less-files).

### Library choice

Keep Flutter's [`file_selector`](https://pub.dev/packages/file_selector) for native
pickers (already used here). [`macos_secure_bookmarks`](https://pub.dev/packages/macos_secure_bookmarks)
is a relevant alternative for minting/resolving bookmarks, refreshing stale
bookmarks, and balancing security scopes. Its documented API covers authorization,
while coordinated reading still needs native integration. Migrating PoDoFo's
existing bookmark persistence and moved-path aliases would be separate work, so
this fix adds no dependency or permission entitlement.

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

### Coordinated reads — 2026-10-29

- 24 focused Flutter regressions passed: persistent access, document notices,
  native open/save/restore behavior, and highlight persistence. New coverage checks
  that native bytes work even when the pathname is unreadable to Dart, grants
  survive pending reads and release on failure, and a missing read bridge cannot
  silently fall back to direct file I/O.
- Native coordinated-read and bookmark-alias regressions passed. Static analysis,
  changed-Dart formatting, and `git diff --check` passed.
- The production reader opened the previously failing TRELLIS.2 Google Drive PDF:
  32,886,191 bytes, 24 PDFKit pages, SHA-256
  `06a8dd9e0b9331a6e336172f96e6544d8a99b6a18b2b1340933e9a0bd6b8462d`.
  Before coordination it had `SF_DATALESS`, zero local blocks, and direct reads
  failed with errno 11. Afterward the dataless flag cleared and a direct read
  returned the PDF header. This was a read-only, unsandboxed native probe using
  production reader code; it did not exercise the Flutter picker or app relaunch.
- The macOS Debug app built and passed deep/strict signature verification. Logs
  are in `podofo_frontend_one/build/coordinated-read-{tests,analyze,build}.log`.
  Existing apps running from other worktrees were not restarted.

### Main integration — 2026-10-24

Merged main at `ba64a49` into the file-access branch. The `PdfSession` import
conflict was resolved by keeping both the file-access bridge and page-relative
navigation history. The existing bookmark open/save implementation and the
current main reader, narration, and two-page controls are retained.

- Locked dependency resolution and static analysis passed with published
  pdfrx 2.6.5 / pdfrx_engine 0.6.1.
- The standard test suite passed **156 tests**, with **4 opt-in native
  MLSR/audio/corpus tests skipped**. This includes access recovery, save failures,
  reader navigation/Save As, and two-page context-menu coverage.
- The native Swift bookmark-alias regression passed.
- The macOS Apple Silicon Debug build and deep/strict signature verification
  passed; the signed app retains sandbox, user-selected read/write, and
  app-scoped bookmark entitlements.
- Logs are retained under `podofo_frontend_one/build/file-access-merge-*.log`
  in the integration worktree. Fresh user-document quit/relaunch acceptance was
  not repeated for this merge; the earlier sandbox probe is described below.

### Commands and coverage

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

The coordinated-read regression uses the production reader to check background
I/O, concurrent requests, symlink resolution, detached bytes, missing-file errors,
and classification of wrapped cloud errors versus permission errors:

```sh
xcrun swiftc macos/Runner/FileAccessStore.swift tool/macos_coordinated_read_test.swift \
  -o /tmp/podofo-coordinated-read-test
/tmp/podofo-coordinated-read-test
```

Optionally add `--read /absolute/path/to/cloud.pdf` to read a real cloud PDF and
report its byte count, PDFKit page count, and SHA-256. This is read-only, but may
download the document. The probe has a 45-second deadline and is not sandboxed;
it does not by itself prove the Flutter app's sandbox or picker lifecycle.

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
