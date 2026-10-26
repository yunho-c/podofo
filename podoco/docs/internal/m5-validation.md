# M5 PoDoFo layout integration validation

Validated on 2026-10-26 on macOS arm64/M4 Pro. M4 is commit `38ad865`;
merge `937a271` brings only the two committed reader fixes from
`feat/highlight-editability` into the Podoco worktree. Uncommitted main-worktree
changes were inspected and left untouched. No recognition or math API is
claimed by this layout-only milestone.

## Implemented boundary

The [application guide](../../../docs/document-analysis.md) describes the lazy
PDF source, locked rendering, copied input, displayed-page coordinates, bounded
page store, revision/generation guards, and Developer-pane controls. The app
uses the public M4 package and a host-prepared native asset. Model selection is
an explicit local directory operation; no model is fetched by a normal build.
The selected mixed layout export retains M2's experimental status.

The controller retains one visible page, reuses its native analyzer, and keeps
progress observation independent of result persistence. Disk writes check the
active revision/generation before work and after staging, immediately before
atomic rename. Unsaved revisions include a session nonce to avoid collisions
between different editing histories with the same numeric revision. Result
cache keys also include the manifest hash, pipeline profile, and raster policy.

## Checks and fixes

Twelve focused application checks cover:

- progressive versus final snapshots, reopening, revision/profile/model cache
  invalidation, bounded eviction, malformed cache files, and a generation change
  during asynchronous staging;
- actual PDF text pixels and coordinate conversion on a cropped page and all
  four rotation values, using 12 native renders;
- switched, edited, and closed documents rejecting late updates, including
  changes that have not yet triggered a UI refresh;
- cancellation while waiting for the PDF session lock, preventing job admission;
- repeated close while model opening is still pending, disposing the late model
  once and sharing the same draining completion;
- real three-page and 64-page jobs through the PDF source/controller, completed
  page restoration, finite mappings, nonempty layout results, bounded input and
  result counters, and zero remaining native handles;
- real model overlays in the reader on cropped and rotated pages, a visible
  pixel difference when toggled, stable document/viewer identities, Developer
  controls, and authoritative final progress;
- failed cache initialization offering explicit retry without background retries.

Testing caught a staging-directory construction error, fixed before accepting
persistence results. Full reader regressions exposed Riverpod's automatic retry
timers for unavailable platform path services; cache initialization now has an
explicit retry policy and a visible retry action. Visual review caught the last
coalesced progress snapshot displaying 2/3 after a completed three-page outcome;
the controller now publishes the outcome's authoritative final progress.

The widget harness advances frames while native analysis runs, rather than
blocking its fake scheduler awaiting completion. Screenshot fixtures load the
app font and a Material fallback alias; they qualify geometry and controls,
not exact production typography. The crop/rotation overlays and control captures
were inspected after the final corrections.

## Native and build evidence

The final reproducible command uses the repository-pinned Flutter 3.47.5 / Dart
3.13.4, the existing Python 3.13, and Rust 1.95.0. Earlier focused checks also
passed with installed Flutter 3.47.7 / Dart 3.13.5; those do not substitute for
the pinned run.

```sh
# From podofo_frontend_one/, after preparing the existing MLSR assets:
python3.13 tool/qualify_podoco_macos.py \
  --bundle ../podoco/model-assets/pp-doclayout-v3-m2 \
  --flutter-sdk /path/to/flutter-3.47.5
```

This passed locked package resolution, Flutter analysis, the host-architecture
Release build, deep/strict local signing verification, and **273 tests with four
preexisting platform/opt-in skips**. No M5 native test was skipped. Formatting passes for all 154 Dart files. The existing generated ObjectBox
file needed formatting normalization; regeneration then reproduced that file and
the unchanged schema exactly. The Windows
workflow now prepares Podoco's portable artifact before resolving the app;
workflow configuration does not establish a remote Windows pass.

The focused real jobs perform 70 layout predictions: 3 source/controller pages,
64 repeated document pages, and 3 reader-widget pages. The long job completes
64 pages, retains only the visible page in the controller, stays within its
16 MiB input reservation and 512 KiB result budget, and drains those charges to
zero. These counters are reservations/SDK accounting, not measured process RSS;
the copying boundary and opaque Core ML allocations are described in the guide.

The exact Podoco and MLSR frameworks from the signed Release app also pass
fresh-process coexistence in both orders, with one real layout prediction per
process and zero retained handles. MLSR is the app's existing pinned
`0ca5d81` SDK/native artifact; the widget check calls its identity API alongside
real layout analysis. This does not claim concurrent synthesis or audible
acceptance. The packaging test does not exercise a sandboxed model-directory
picker or the complete Copy/Listen workflow; those remain M9 acceptance work.

The compact [summary](../../tests/fixtures/pp_doclayout_v3/m5-summary.json)
records tool versions, model/source/native hashes, test result, and screenshot
hashes. Full logs, captures, and coexistence outputs remain in ignored
`podofo_frontend_one/build/podoco-qualification/20261026T073446Z/`.

The geometry fixtures and 64-page document are original generated PDFs. They
establish lifecycle/transport behavior rather than broad layout quality. M2's
mixed-precision export discrepancies remain promotion blockers, and this
milestone does not qualify the 144 dpi policy for formula recognition.
