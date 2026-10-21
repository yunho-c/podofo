# MLSR paper narration

Implementation branch: `feat/mlsr-tts`. The first supported listening target is
macOS Apple Silicon, macOS 15 or later. Other desktop targets keep the PDF reader
and expose listening as unavailable until their runtime/output is qualified.

All four milestones are complete for this scope. Automated qualification and the
author's successful manual acceptance review are recorded in
[qualification](tts-qualification.md).

PoDoFo owns PDF extraction, reading order, source maps, document navigation and
bookmarks. MLSR owns inference, model segmentation, PCM, native playback, timing,
cancellation, and bounded temporary audio retention. One application-owned engine
serves one active narration session independently of the visible tab.

## Milestones and acceptance

1. **Packaged selected-text listening.** Pinned, offline model delivery; lazy
   persistent engine; native pause/resume and stop; injectable lifecycle tests;
   unsupported desktop builds remain viable. Commit after focused tests and a
   native macOS build/playback check.
2. **Source-mapped controls.** Temporary PDF highlights, sentence navigation and
   source-anchor starts. Verify Unicode, ligatures, cropped/rotated geometry,
   switching tabs, save/close races and safe shutdown.
3. **Continuous papers.** Bounded paragraph passages across pages, reviewed
   single-/two-column reading order, explicit uncertain/scanned content, and
   per-paper source bookmarks. Preserve ObjectBox UIDs. Verify long-input and
   cleanup bounds and resume behavior.
4. **Release qualification.** Sandboxed relocated offline release; real listening
   review; first-audio and passage-transition measurements; sustained native
   handle/memory/storage bounds; regression and platform build evidence.

Each milestone is independently reviewable and committed after its checks. A
build, muted playback test, and audible review are distinct evidence. Remaining
gates stay explicit until exercised.

## Invariants

- A passage is below MLSR's 64 KiB UTF-8 request limit; input is never truncated.
- Prepared speech text retains a mapping to one or more original PDF ranges.
- PDF native access uses the existing session/lease, with immutable snapshots
  released before speech; annotation-only edits do not invalidate spoken text.
- Native extraction is serialized; layout analysis runs on detached snapshots
  after that lock exits. Text for the next page may be prepared during playback,
  without creating another speech handle or advancing the source cursor.
- Native `Speech.done` completion, not synthesis completion, advances passages.
- Cancellation/failure never advances narration. Late callbacks cannot restart it.
- Source text anchors are durable; request IDs, sentence IDs and frame offsets
  belong to one frozen request. Reopening resumes at a validated sentence anchor.
- Temporary listening paint never writes PDF annotations or triggers auto-save.
- Voice and synthesis speed replace from the current source sentence. Playback
  rate stays 1.0. Native pause/resume preserves the live cursor.
- Timeline scale is final duration or whole-request estimate, never buffered PCM.

## Build preparation

`python3 tool/prepare_mlsr.py` in `podofo_frontend_one` obtains the exact SDK
revision and builds the host's native library before `flutter pub get`. On Apple
Silicon it also prepares verified offline model assets from `mlsr-models.yaml`.
The model must already be available locally; no weights download implicitly.
`--sdk-source /path/to/MLSR` permits an offline local Git source while still
checking out the pinned revision. Other native desktop hosts create a model-free
package and a portable native library; no Apple feature flags are applied there.
Generated SDK, build outputs and weights live under ignored `.mlsr/`.

Use Python 3, Rust (the SDK selects its toolchain), Flutter 3.47.5, Xcode and
CocoaPods. From the app directory, after making the model bundle named in
`mlsr-models.yaml` available locally:

```sh
python3 tool/prepare_mlsr.py
# Optional offline SDK source: --sdk-source /path/to/MLSR
../.fvm/flutter_sdk/bin/flutter pub get --enforce-lockfile
bash tool/build_macos_local.sh release
python3 tool/test_macos.py
```

The FVM path is optional; use the pinned `flutter` executable on PATH or set
`FLUTTER_BIN` for the build helper. The release app is
`build/macos/Build/Products/Release/PoDoFo.app`. It is locally ad-hoc signed and
sandboxed, not notarized for distribution. Both the Flutter plugin and app now
require macOS 15; older macOS build notes predate MLSR.

For the full packaged check, run `python3 tool/qualify_mlsr_macos.py`. It builds a
separate probe entrypoint, clones the bundle outside the checkout, verifies all
asset hashes/signatures/linkage, then exercises real plugins and muted native
playback with denied network/developer-file access. It restores and audits the
normal Release app in a `finally` step. Logs, report and sample WAV are retained
in a new `build/mlsr-qualification/<timestamp>/` directory, with the relocated app
in a temporary directory named in the report. Never nest `sandbox-exec` around
this already-sandboxed app; macOS traps before Flutter starts. See
[qualification](tts-qualification.md) for evidence and the manual acceptance record.

On Windows, run `python tool/prepare_mlsr.py` before the ordinary locked package
resolution and `tool/verify.ps1`. This produces a model-free package and portable
native library for the host. It does not enable Windows speech.

The existing local macOS modernization and unrelated icon/document edits were
present before this work and are preserved. A baseline patch and the abandoned
2025 Git sequencer metadata are backed up under `.git/mlsr-tts-baseline/`.

## Document timeline: compact index

The document-timeline prerequisite milestone 2 adds an in-memory index to each
`PaperSequence`. `PaperPagePlanner` is shared by preview, playback, prefetch and
indexing, so they use identical reading order, exclusions and passage boundaries.
`PaperIndex` publishes immutable progress snapshots in document order. A passage
descriptor contains the plan revision/options, page and ordinal, a context-free
source anchor and page hash, normalized spoken-text hash, UTF-16/scalar counts,
Unicode letter/mark/number run count, and punctuation count. It retains no spoken
text, glyph geometry, native PDF objects or audio.

Playback admission seeds the full starting page even when narration starts inside
a passage. After speech admission, the controller starts indexing alongside
next-page preparation. Playback takes priority over prefetch, which takes priority
over indexing; matching in-flight page/options requests share work and can be
promoted. One extraction lane checks cancellation and priorities between target
and neighbor reads. A lower-priority plan releases its snapshots and retries after
foreground work; an already-entered native extraction must finish first. Detached
page analysis remains synchronous, with event-loop yields between pages and
neighbor reads. The existing two-page playback cache stays separate from index
metadata, so scanning cannot evict the current/next playback pages.

Indexing continues while paused. Stop cancels pending work and rejects stale
results while retaining completed metadata; Play resumes the missing work.
Document close/replacement clears the index. Global reading-option changes reset
its revision and detailed cache; page review/skip invalidates only that page's
metadata. A fresh playback extraction replaces metadata when its text hash
changes. Annotation saves and Save As preserve valid entries. No persistence or
schema changes are involved.

The earliest known References stop bounds the exposed scope. Missing, ambiguous,
scanned or failed pages before that boundary prevent `fullyResolved`, even when
`scanFinished` is true. Background failures remain per-page issues and do not
interrupt narration or open the active review flow. Call
`indexDocument(retryFailures: true)` to retry extraction failures. Duration
estimates, measured-audio reconciliation and whole-document scrubbing remain later
milestones; the current transport remains passage-based.

Validation on 2026-10-20: 94 Flutter regressions pass, static analysis passes, and
the separate muted native playback test passes, including the existing revised
Previous-at-beginning behavior and handle cleanup. Coverage includes priority/promotion,
Stop/restart and option-change races, close during extraction, continued indexing
while paused, unresolved reference scope, page review/skip, changed-text identity,
Unicode, annotation saves and Save As, and real-PDF index/preview parity. A
250-page synthetic document retains two detailed playback pages and permits only
one concurrent extraction; its compact descriptor-array JSON is 45,393 bytes.
That serialization measure is not Dart heap or process RSS accounting.

The existing local ViT and ResNet PDFs were each measured in three separate test
processes, interleaved by document, using default reading options and a readable
starting page (ViT 2, ResNet 3). Timing includes the remaining scan and next-page
prefetch after the starting page is prepared; it excludes PDF open, the seed plan,
parity verification and speech. These are active-host diagnostics, not a
first-audio or UI frame-latency benchmark.

| PDF | Pages / indexed scope | Passages | Unresolved pages | Scan + prefetch | Metadata JSON |
| --- | --- | --- | --- | --- | --- |
| ViT | 22 / 22 | 75 | 17 | 289–317 ms | 26,507 bytes |
| ResNet | 12 / 9 | 24 | 7 | 159–169 ms | 8,870 bytes |

Both keep two detailed cached pages and one concurrent extraction. Every indexed
page matches a fresh preview's issue, source hash, stop marker, passage count,
anchor offsets and spoken hashes. The automatic planner's existing uncertain
pages remain unresolved; these partial scopes do not represent complete readable
documents. Real-PDF metadata JSON includes page status and named descriptor fields,
so its byte count is not directly comparable to the synthetic descriptor array.
Reports and input hashes are under
`podofo_frontend_one/build/mlsr-qualification/document-index-20261020-v2/`.

Reproduce one run from the app directory, choosing a new output file:

```sh
PODOFO_PDF=build/mlsr-qualification/corpus/vit.pdf \
PODOFO_INDEX_START=2 \
PODOFO_INDEX_OUTPUT=build/index-vit-new.json \
python3 tool/test_macos.py tool/benchmark_paper_index_test.dart
```

## Progress

- Document-timeline prerequisite, milestone 1: Stop, close and replacement retain
  the last native source anchor; failed initial loading can be retried through
  Play. At the paper boundary, Previous restarts the first sentence and preserves
  the user's pause intent.
  Across passages, Previous Sentence starts the destination paused, waits for its
  native duration/sentence plan, selects its final sentence, and restores the
  user's pause intent. Completion and stale plan callbacks cannot race that move.
  Validation: 79 Flutter regressions pass (the opt-in native test is separate);
  the expanded muted native test passes backward navigation while playing and
  paused, checks presented sentence positions, and returns handles to baseline.
  The persisted-bookmark regression exercises Stop, close and reopen. Document
  indexing is implemented above; duration estimates and the whole-document
  scrubber are later work.
- Branch created; stale sequencer metadata safely quit after backup.
- Milestone 1: selected-text listening, native pause/resume, cancellation and
  application/document cleanup implemented. The pinned engine and 10-voice model
  package prepare successfully, including an idempotent second preparation.
- Validation: 33 Flutter regressions pass (native speech opt-in skipped in this
  suite); the separate 62-second real Core ML/native-output test passes, including
  model reuse, frozen pause cursor, resume, completion and native handle cleanup.
  Audio was muted. Two preparation tests and Flutter analysis pass. macOS arm64
  Release builds and nested code-signature verification pass.
- `python3 tool/test_macos.py` loads PDFium and ObjectBox from the Release bundle.
  `PODOFO_TEST_MLSR=1 python3 tool/test_macos.py test/narration_native_test.dart`
  also exercises real synthesis/output. It mocks only plugin path discovery;
  relocated sandboxed plugin operation and audible review were deferred to
  milestone 4.
- Windows CI prepares a portable native library and model-free package before
  dependency resolution. The executed Windows build and regression gate now
  passes; see the qualification record for its exact commit and artifact.
- Milestone 2: detached, hashed page text and UTF-16 source maps; ligature and
  whitespace normalization; temporary sentence paint; follow/show-location;
  native sentence navigation and passage timeline; voice/language/synthesis-speed
  controls. Selection and page extraction share the session's edit/save/close
  lock. The PDFium scalar-to-UTF-16 conversion runs before page formatting.
- Validation: 42 Flutter regressions pass with one opt-in native test skipped;
  analysis passes. Real PDF fixtures cover emoji/ligature extraction, crop and
  rotation paint, annotation-only save identity, and snapshot/close serialization.
  The reader test covers active speech across another tab, cancelled dirty close,
  save and final close. Temporary paint was inspected in the generated reader
  capture; native app visual/listening review was a separate release check.
- Milestone 3: continuous bounded passages, a reading-order preview with explicit
  single-column/two-column/PDF-order choices, references/caption options, and
  review/skip handling for ambiguous or textless pages. Two page plans are cached;
  passages cap raw text at 4 KiB and normally split earlier at sentence endings.
  Only successful native playback completion advances. Per-paper bookmarks store
  page, source offset, text hash and mapping version, and survive reopen/Save As.
- Validation: 55 regressions pass, with the opt-in real speech test skipped;
  analysis passes and repeated ObjectBox regeneration is byte-identical. Legacy
  schema IDs are preserved. Tests include real two-column PDFs, 24-page traversal
  with a scanned page, bounded page caches, changed-text resume rejection, delayed
  close versus a new request, and pause/stop during page preparation.
- Reading order is a conservative geometric heuristic, reviewed before starting.
  It is not semantic PDF understanding or OCR. Footnotes and unconfirmed marginal
  text remain in the stream. Confirmed repeated margin lines are optional;
  ordinary compound hyphens are preserved, while witnessed line-end splits and
  explicit soft hyphens can be joined with source mappings retained.
  Complex tables, mixed scripts/layouts and equations can need explicit PDF order
  or selection. No whole-paper duration is fabricated from the current passage.
- Milestone 4 automated portion: relocated sandboxed Release playback and exact
  bundle audits pass, with repeatable tooling that restores the ordinary app.
  Native pause/navigation, continuous drain, persisted source position, repeated
  cancellation and engine/PCM cleanup pass. The 760×520 reader/preview checks
  also pass. Timing/resource observations and native-window/human listening
  results are recorded in [qualification](tts-qualification.md).
- Completion-audit follow-up: source-to-speech lookup now finds the containing
  source span even when extraction order differs from reading order. Page plans
  expose paragraph/heading/caption/reference/excluded-margin blocks. Margin
  detection uses up to four nearby pages, one temporary snapshot at a time;
  two prepared page plans remain the persistent cache bound. Preparation shares
  in-flight page work, and cancellation invalidates it before publication.
  Bookmarks add bounded context and plan version without changing existing UIDs.
  The preview exposes exclusions and labels its 16,000-character display limit.
- The expanded 63-test suite passes, including a real four-page corpus with
  alternating headers, page numbers, scientific notation, cross-page prose and
  two columns; source reorder and PDFium hyphen-marker regressions; cancellation
  versus replacement prefetch; and dark-theme reader ownership. Static analysis
  and repeated schema generation pass. The ordinary widget engine cannot run
  Impeller image filters; the Release probe checks inversion with offscreen
  source-region pixels under the real renderer.
- The real-paper review compared a single-column ViT body page and two-column
  ResNet body page to their PDFium renderings. It caught joined-word geometry
  spanning lines and a footer-position gap; regressions now cover those cases,
  vertical marginal text and reversed PDF word emission. Complex pages require
  explicit review. See the qualification record for inputs and exact scope.
- Two extended sandboxed runs each complete 184 warm cycles over three minutes.
  Every stop releases PCM/stores, shutdown returns native handles to zero, and
  cache bytes/file counts stay unchanged during the warm loops. Engine loading
  adds specialization-cache artifacts, so relocation/upgrade storage is a
  separate boundary. The final-source probe records source hashes and restores
  the normal signed Release app.
- After the authorized push, [Windows CI run 39524485170](https://github.com/yunho-c/podofo/actions/runs/39524485170)
  passes on `359546e`: native MLSR preparation, locked dependencies, formatting,
  ObjectBox generation, analysis, x64 Release build and 63 regressions (one
  macOS-native speech skip). The uploaded archive's digest and AMD64 binaries
  are verified, and it contains no MLSR model payload. This closes the Windows
  build gate without expanding the supported listening platforms.
- Manual acceptance completed on 2026-10-20: the author approved the exported
  listening sample, confirmed actual app playback, and reported satisfactory
  results after completing the native UI checklist. This closes milestone 4 and
  the implementation goal for macOS Apple Silicon.
