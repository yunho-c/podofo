# PoDoFo stabilization and modernization

This work addresses review findings #2–#8. The agreed product scope is a working
PDF reader with persistent highlighting and saving. AI search/chat, study,
audio, extensions, timeline, utilities, printing, and export remain explicitly
disabled. The annotation pane now lists and removes actual PDF highlights.

## Dependency migration

Flutter is pinned to **3.47.5** (Dart **3.13.4**) in `.fvmrc`. The committed
lockfile uses published packages; neither sibling checkout is required or modified.

| Component | Decision |
| --- | --- |
| pdfrx | 2.6.5; migrate to its selection delegate/context-menu API and attached-controller search lifecycle |
| Riverpod | 3.4.3; handwritten Notifiers, explicit legacy StateProvider imports where appropriate |
| ObjectBox | Runtime, native libraries, and generator 5.3.2 together |
| shadcn_flutter | Published 0.0.54; updated theme, controls, outline, and Material bridge |
| File dialogs | Flutter's file_selector 1.1.0 replaces file_picker; Save As needs a destination-only API so the application controls validation and replacement |
| Code generation | build_runner 2.15.1 is deliberately pinned: newer versions require an analyzer version incompatible with ObjectBox's current generator |
| Other packages | Compatible transitive upgrades are locked; unused Hive, Dio, Google Fonts, Riverpod generation, HTTP metadata parsing, and global hotkeys were removed. Font Awesome 11.0.0 supplies the restored highlighter icon with the current Flutter API. |

The older pdfrx selection-color fallback and shadcn selection/radio-export patches
are no longer required by the migrated UI. Their original branches remain intact.
Development forks can be selected through an ignored `pubspec_overrides.yaml`.

Primary references: [pdfrx migration history](https://pub.dev/packages/pdfrx/changelog),
[Riverpod 3 migration](https://riverpod.dev/docs/3.0_migration),
[file_selector destination API](https://pub.dev/documentation/file_selector/latest/file_selector/getSaveLocation.html).

## Schema and startup

`UserState.autoSaveEnabled` explicitly retains property UID
`8031658732022810243` (ID 16). Only the inconsistent JSON name
`enableAutoSave` changes; no entity or property identities are reset.
The legacy model fixture and a real native database round trip protect stored
preferences, document pages, history, and thumbnail records.

Saved documents restore independently. Missing, inaccessible, password-protected,
and corrupt files produce recovery notices with Retry and Remove from session.
Other PDFs remain available. Opening a recent file uses the same error path.
Canonical file paths prevent duplicate live sessions; legacy duplicate records
are coalesced. Closing a tab selects a valid remaining tab. Invalid stored page
numbers and palette indices are normalized.

The database remains in the existing Documents/`obx-docs` location. No database
reset is used for migration or recovery. Old thumbnails are disposable derived
data: their path-only records are cleared at initialization, while the old entity
stays in the schema to preserve compatibility.

## Ownership and previews

Each tab owns one detached PDF session. The viewer receives that session's
`PdfDocumentRefDirect`; outline, annotation, and thumbnail operations retain a
lease while working. Closing releases the owner; pdfrx disposes the native PDF
after viewer references and pending jobs finish.

Thumbnails render only for visible/nearby pages through one render queue. Raster
sizes follow the card size and display pixel density, in 64-pixel buckets capped
at 1024 × 1536 pixels. Leaving a pane or switching documents cancels work. Native
images are disposed in `finally`; JPEG encoding runs off the UI isolate.
The LRU stores at most 128 thumbnails / 8 MiB and keys entries by content hash,
edit revision, page, and raster size. There is no persistent thumbnail cache to
become stale or grow indefinitely.

The original card styling, spacing, focus navigation, and dark-mode inversion
are restored without visible page captions. Card heights follow each PDF page's
dimensions rather than a fixed portrait ratio. The initial viewport uses
one pane-level loading indicator; later pages still load on demand. See
[thumbnail-restoration.md](thumbnail-restoration.md) for the before/after table.

Link cards now display the actual destination. Hovering never fetches web
metadata or remote images. This deliberately replaces the former automatic
Open Graph request rather than adding an opt-in network client in this release.
Generation guards, lease ownership, and overlay cleanup handle hover exit,
document switching, and disposal. Only an explicit click can launch HTTP/HTTPS
URLs; embedded credentials and arbitrary executable/file schemes are rejected.
The duplicate macOS sandbox entitlement was removed. No preview-network
entitlement is needed for destination-only cards.

## Highlighting and saving

The highlighter button toggles highlighting mode; enabling it also highlights
an existing selection. While enabled, completed selections become highlights,
with pointer tracking preventing a paused drag from committing prematurely.
Right-click or long-press the highlighter for the compact color palette and
inline custom-color picker. The selection context menu includes color swatches
that apply a highlight directly, even when highlighting mode is off.
Ctrl/Command+Shift+H also highlights the current selection. Color choices persist.
Empty selections quietly do nothing. Empty pages and text fragments without
usable bounds are skipped, so they do not prevent valid text from being highlighted.
Concurrent requests for the same selection are coalesced, and switching documents
during selection extraction cancels the pending action. Highlights are native PDF highlight
annotations with text attachment points, color, printable flags, and selected
text where copying is permitted. Cropped-page offsets and page rotation are
covered by native tests.

The annotation pane lists highlights page by page and can remove highlights
saved in earlier sessions. The session API supports undoing a newly added batch,
but the added Undo menu entry was removed during UI cleanup. Arbitrary deletion
clears that batch undo history; general document undo/redo is not advertised.

Save, Save As, and auto-save use the same serialized session operations. A dot
on the tab identifies unsaved changes. Auto-save failures preserve edits and
display an error. Tab closure, keyboard quit, and native window closure honor
Save / Discard / Cancel. Closing the window preserves its document list for
restoration.

Saving a modified PDF encodes and reopens the result for validation before
replacing any file. Saving an unchanged document is a no-op; Save As copies its
original bytes without re-encoding.
A flushed temporary file on the same filesystem is renamed into place. Source
fingerprints are checked before staging and immediately before replacement;
an external change produces a conflict and Save As preserves both versions.
Save As cannot overwrite another open tab. All failure paths preserve dirty
state until a write commits. Signed PDFs and PDFs that prohibit annotation
modification are treated as read-only for highlights.

## Verification and practical limits

The suite includes UID identity checks, legacy native database migration,
missing/corrupt-file recovery, tab normalization, PDF lifetime races,
cropped/rotated multi-page highlights, native rendering, undo/removal,
manual and automatic saving, external conflicts, Save As session records,
bounded cache behavior, inert link handling, and real-reader widget interaction.
The Windows CI workflow regenerates the model, checks formatting and analysis,
builds the release application, and runs these regressions with its ObjectBox DLL.

A discovered ARM-host/x64-target mismatch is fixed in project CMake: ObjectBox's
download architecture follows the Visual Studio target rather than the host.
A successful linker run alone had not detected the incompatible DLL.

Validation is performed on Windows, using the x64 Flutter test engine on an ARM64
host. macOS/Linux release behavior has not been exercised here. In particular,
macOS sandbox access to previously selected files and atomic Save As destinations
requires platform testing before distributing that build. Mobile and web are
not supported by this desktop work.

PDF sessions currently retain detached source bytes in memory to avoid locking
the source file during replacement; very large files have a corresponding
memory cost. Undo is limited to newly added highlight batches. Password entry,
general annotation editing, and rich network previews are outside this release.
Fingerprint checks detect ordinary external edits, but do not claim a transaction
with an unrelated program writing in the final check/rename interval. Unsaved
edits are not a crash-recovery journal.

The final command results are recorded in [validation.md](validation.md).
