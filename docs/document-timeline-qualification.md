# Document timeline qualification

The document scrubber uses MLSR's duration model through the public `Tts`
facade. A complete scale requires a resolved reading scope and timing for every
included passage. The application does not estimate missing pages from word
counts. Presented native frames determine playback position; retained PCM only
describes readiness. [Implementation details](tts-implementation.md) cover the
index, timing, source-navigation transaction, and frozen drag mapping.

The version-2 qualification regression suite passed 117 tests with three opt-in native cases
skipped; those three cases also pass separately against the prepared real model.
Flutter analysis is clean. The narrow 360-pixel partial and hour-scale complete
captures were inspected. The timeout regression confirms that an unconfirmed
seek keeps the previous source position and cancels the pending playback.

The historical corpus results below compare the former automatic and explicit
PDF-order modes. Reading-plan version 3 removes those alternatives and changes
paragraph boundaries; the old passage counts and duration coverage are not
measurements of the current planner. See [reading-plan changes](tts-implementation.md#reading-plan-version-3)
and [current extraction checks](tts-qualification.md#reading-plan-version-3--2026-10-21).

## Reproduce

Run from `podofo_frontend_one` on macOS Apple Silicon after preparing MLSR and
building the native app dependencies:

```sh
python3 tool/test_macos.py
PODOFO_TEST_MLSR=1 python3 tool/test_macos.py test/narration_native_test.dart
PODOFO_TEST_MLSR=1 python3 tool/test_macos.py test/document_timeline_native_test.dart
PODOFO_TEST_MLSR_CORPUS=1 python3 tool/test_macos.py test/document_corpus_native_test.dart
python3 tool/qualify_mlsr_macos.py --stress-seconds 30
```

The corpus check defaults to the saved ViT and ResNet PDFs under
`build/mlsr-qualification/corpus`. `PODOFO_TIMELINE_CORPUS` accepts a JSON array
of local PDF paths; `PODOFO_TIMELINE_REPORT` selects the output JSON. It now uses
PDF text order only and records the reading-plan version, hashes, coverage,
native errors, timing and handle counts. Only resource-path discovery is mocked
in the Flutter test runner; PDFium extraction and Core ML inference are real.

The release probe builds a separate entrypoint, relocates the signed app, launches
it through macOS Launch Services (`open -n -W`) and
checks that the macOS Sandbox denies developer-file and network access. Its
document test starts on page 6 of a 14-page generated PDF, plans 12 passages,
stops at References on page 13, and excludes the appendix. It checks 24 alternating
cross-page seeks, native confirmation, paused/playing intent, bookmarks, exact
start, endpoint clamping, Stop during a pending seek, and replanning at both
0.9x and 1.3x. Two detailed cached pages and twelve timing records remain the
limits for that fixture. Stop must release all retained PCM; final teardown must
return native handles to baseline. The harness always rebuilds and audits the
ordinary app in `finally`, including when the probe fails.
The probe exports its fixed artifact set through stdout with SHA-256 digests;
the host does not need permission to read the app's protected container.

The pinned SDK revision is `c2b7408f4a6950617099eea433d768623f352b26` on the
local `feat/document-duration-api` branch. Publish that SDK revision before
expecting a fresh remote checkout to fetch it. Local preparation can use
`python3 tool/prepare_mlsr.py --sdk-source /Users/yunhocho/GitHub/MLSR-document-duration`.
The SDK's own qualification covers priority/preemption, cancellation, compact
timing DTOs, prediction/render consistency and C/Dart/Go/Python bindings.

## Real-paper coverage

The saved PDFs are ViT, arXiv `2010.11929v2` (SHA-256
`8ce7b83971a14508ca711a27c875c9b6914c4f6767cf3150fb1ca6c07aa056d6`), and
ResNet, arXiv `1512.03385v1` (SHA-256
`1e0651b6810ecba34a3dbc5b5b0209226f889004607c1f203540a48d64e5a93a`).
These results exercise the conservative current reading policy, not a claim that
arbitrary research PDFs can be narrated without review.

| PDF / order | Timed / indexed passages | Unresolved pages | Failed passage timings | Complete scale |
| --- | ---: | ---: | ---: | --- |
| ViT / automatic | 75 / 75 | 17 | 0 | No |
| ViT / explicit PDF order | 39 / 45 | 0 | 6 | No |
| ResNet / automatic | 24 / 24 | 7 | 0 | No |
| ResNet / explicit PDF order | 46 / 47 | 0 | 1 | No |

The explicit PDF-order cases reach References on page 9. ViT's automatic scope
remains provisional across 22 pages because earlier review gaps include the
reference boundary. The native failures include unsupported scientific symbols
and extracted control characters. They remain visible failures, with a retry
action; no unsupported passage silently contributes zero seconds. All four
cases correctly withhold total duration and document seeking. Planning alone
retains no detailed playback pages and returns to one engine handle after each
case, then the baseline after disposal.

## Limits and interpretation

- Duration is media time at the selected synthesis speed. Model loading,
  buffering and pauses are excluded. The UI speed presets are 0.9–1.3x in 0.1
  increments; native playback rate remains 1.0.
- Unresolved reading order, OCR-only pages and native unsupported text prevent
  a complete scale. The passage scrubber remains available while document
  coverage is incomplete. Explicit skips and References change included scope.
- Unrendered segment durations are predictions. Generated segment lengths replace
  matching predictions. Resuming a text suffix maps source ranges approximately
  because slicing can change segmentation; the UI marks approximate position.
- Dragging freezes source mapping. Release issues one seek; cancellation,
  settings/scope changes or a different document invalidate stale work. During
  native preparation, the thumb remains at the previous committed position and
  a loading label appears. A newer seek can replace the pending destination.
- Seek preparation times out after 30 seconds and keeps the previous committed
  location. Cancellation cannot interrupt a PDF/native call already executing,
  but waits for ownership to quiesce and discards stale results.
- Index and timing metadata grow with included passages/segments. Detailed PDF
  playback plans stay bounded to two pages, plus temporary background work.
  Native reader audio remains quota-bound. No timing cache is persisted.
- Automated output is muted. Native presented-frame checks validate scheduling
  and device progress, not acoustic onset, pronunciation or perceived quality.
  Latencies in receipts are local diagnostic observations, not a controlled
  performance comparison or an accuracy study across languages and voices.

## Evidence

The final `milestone6/release-complete` runtime passed on 2026-10-21 with the
updated SDK: 24 document seeks, both rate limits, 40 warm reuse/cancellation
cycles, developer-file/network denial and final native handles `0 → 0`.
The detailed page cache peaked at two pages; retained PCM was zero after Stop
(923,668 bytes peak in this run). The bundle audit covers 50 packaged assets,
native linkage and sandboxed signing.

Diagnostic observations from that run: engine open 22.31 s, first presented
document frame with the warm engine 295 ms, complete 12-passage coverage 2.47 s,
and paused-seek confirmation median 1.15 s / maximum 3.17 s. Replanning plus a
seek took 4.30 s at 0.9x and 13.16 s at 1.3x. These include application scheduling
and native readiness; they are not duration-model inference benchmarks. Warm
controls were faster, so no portable latency guarantee is inferred.

Milestone logs, source/binary/model hashes, bundle audits, runtime receipts and
captures are kept under the ignored app directory
`build/document-timeline-qualification/`. The qualification keeps failed runs
separate from passing runs. The release receipt identifies exact source inputs,
including local changes; unrelated existing user edits are not part of the
timeline commits.

Qualification found and fixed two lifecycle problems. PoDoFo removes a duration
job from its cancellation slot before asynchronous disposal closes the handle;
a blocked-disposal regression verifies that Stop/settings/seek cannot call the
closed handle. MLSR's Apple output now restores buffer readiness after a
configuration notification while preserving pause, avoiding a Resume/readiness
circular wait. A deterministic muted native notification test fails before that
fix and passes afterward, alongside the existing native lifecycle test.

Earlier cold release runs retained a pending native readiness flag and reached
the seek timeout; their source positions and final handle cleanup remained
correct. Warm controls passed, so launch method alone was not established as a
cause. Those failed receipts are retained. No timeout was extended and no seek
was accepted before native readiness. Physical device changes and acoustic
behavior remain outside this automated qualification.
