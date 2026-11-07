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

File coordination currently covers opening. Saves use the metadata-preserving
publication described below. File coordination and sandbox authorization are
separate: coordination does not grant access or bypass an offline provider.

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
validation, and same-volume staging protect the destination.

After flushing and validating the staged PDF and checking the target fingerprint
again, macOS publishes it through `DocumentFileReplacement` on a background queue.
For an existing target, `FileManager.replaceItemAt(..., options: [])` preserves
the target's **Created** date, permissions, and Finder metadata. The contents and
**Modified** date come from the staged file. This applies to Save, auto-save, and
Save As when overwriting an existing destination. Save As to a new path moves the
staged file into place with its own fresh creation date; it refuses to overwrite
a destination that appeared after the final conflict check. Other platforms keep
their existing rename behavior.

If native publication fails, edits remain dirty and the staging directory is
retained: Foundation can move the original during a failed replacement, so
unconditional temporary-directory cleanup could delete recovery data. The error
includes the staging path and any original-file recovery location reported by
Foundation. Pre-publication conflicts and successful saves still clean up their
staging directories. There is no fallback to a metadata-losing rename if the
native method is missing.

After replacement or Save As, the bookmark is refreshed. If refreshing fails,
the committed PDF remains saved and clean; the UI reports that permission may
need granting again next launch.

## Validation

### Isolated metadata branch verification — 2026-11-07

The metadata-only changes were reproduced on `fix/macos-file-metadata` from
`main` at `758a612`, in the sibling `podofo-macos-file-metadata` worktree.

- The original Dart `temporary.rename(target)` publication operation was run
  against a disposable file with a January 1, 2020 creation date. Its creation
  date changed, reproducing the metadata loss independently of the Flutter UI.
- The production Swift replacement regression passed for repeated saves,
  creation/modification dates, permissions, Finder labels, new/existing Save As,
  missing staged files, and destination collisions. The bookmark-alias and
  coordinated-read native regressions also passed.
- All 43 focused Flutter tests passed in `persistent_file_access_test.dart`,
  `native_regression_test.dart`, `highlight_persistence_test.dart`, and
  `annotation_editing_test.dart`, including auto-save and recovery paths.
- Static analysis, changed-Dart formatting, and diff checks passed.
- The macOS Debug app built successfully, including the native Flutter bridge;
  local signing and deep/strict signature verification passed.

Logs and the before-fix reproduction are in
`podofo_frontend_one/build/macos-file-metadata/` in that worktree. Flutter tests
used the existing main-worktree Release bundle's ObjectBox and PDFium libraries;
their paths and SHA-256 hashes are recorded in `native-dependencies.json`.
Prepared MLSR/Podoco dependencies are linked from the main worktree, with
separate build and test caches. LFS assets were hydrated from hash-verified
local copies before the successful test run.

The built app was not launched. The historical sandbox grant/restore probe below
was not repeated in this verification; native file-picker and Flutter UI save
behavior were not exercised.

### Save metadata preservation — 2026-10-29

- 43 focused Flutter regressions passed across persistent access, native
  open/save/restore behavior, highlight persistence, and annotation editing.
  New cases cover new/existing Save As routing, access held during publication,
  retained edits/recovery files on replacement failure, and a missing native
  replacement method. A test-double failure deliberately moves the original
  into staging to verify that cleanup cannot delete it.
- The native metadata regression passed: repeated saves retain creation date,
  POSIX permissions, and Finder label while contents and modification date
  update; a new copy gets a fresh date; an overwritten destination retains its
  own date. Missing staged files and destination collisions preserve old data.
- A signed sandboxed probe saved an external disposable fixture while retaining
  its January 1, 2020 creation date. A fresh process was denied direct access,
  restored the bookmark, and read the updated contents with the same creation
  date. Results are under `ignore/macos-save-metadata-4zhhfg6p/`. The picker was
  not automated; the probe's successful grant/save result was verified before
  running the fresh-process restore. This is native-probe evidence, not a Flutter
  UI save test.
- Static analysis, changed-Dart formatting, and diff checks passed. The macOS
  Debug build and deep/strict signature verification passed. Logs are in
  `podofo_frontend_one/build/save-metadata-{tests,analyze,build}.log`.

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

The metadata regression checks repeated saves, creation versus modification
dates, permissions, Finder labels, new and existing Save As destinations, and
failed replacement/collision behavior using the production native publisher:

```sh
xcrun swiftc macos/Runner/FileAccessStore.swift tool/macos_file_replacement_test.swift \
  -o /tmp/podofo-file-replacement-test
/tmp/podofo-file-replacement-test
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
The probe refuses to modify another path or contents. It reads, stages, performs
the production native replacement, checks the creation date, refreshes the
bookmark, and exits. Results are in `probe-result.json`
under `~/Library/Containers/<bundle-id>/Data/`.

Copy the result, then launch the same signed probe without arguments. Require
`success: true`, `deniedBeforeRestore: true`, `scopeStarted: true`, and
`restoredRead: "persistent-access-after-save\n"`. This distinguishes restored
permission from a path that was already readable. Also require matching
`creationDateBefore`, `creationDateAfter`, and `restoredCreationDate` across the
grant/restore results. Move only the fixture while
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
