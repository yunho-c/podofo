# MLSR paper narration

Implementation branch: `feat/mlsr-tts`. The first supported listening target is
macOS Apple Silicon, macOS 15 or later. Other desktop targets keep the PDF reader
and expose listening as unavailable until their runtime/output is qualified.

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

The existing local macOS modernization and unrelated icon/document edits were
present before this work and are preserved. A baseline patch and the abandoned
2025 Git sequencer metadata are backed up under `.git/mlsr-tts-baseline/`.

## Progress

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
  relocated sandboxed plugin operation and audible review remain milestone 4.
- Windows CI prepares a portable native library and model-free package before
  dependency resolution. Windows build execution remains a release gate; a
  macOS build is not evidence for Windows runtime compatibility.
