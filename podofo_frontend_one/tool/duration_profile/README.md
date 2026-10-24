# Warm document duration profiling

This diagnostic measures document planning after Tts has opened and completed
warmup duration jobs. It does not modify models, the prepared SDK, or the running
app. Foreground playback is muted. No optimization is applied.

From `podofo_frontend_one`, with the existing prepared Apple Silicon models and
native libraries:

```sh
python3 tool/duration_profile/run.py \
  --pdf build/mlsr-qualification/corpus/resnet.pdf \
  --output build/duration-profile/new-run
python3 tool/duration_profile/summarize.py \
  build/duration-profile/new-run/app/app.json \
  build/duration-profile/new-run/process-0.json \
  build/duration-profile/new-run/process-1.json
```

The output directory must be new. The launcher uses the repository's FVM SDK,
resolves already-cached Dart dependencies offline, and builds a small AOT CLI
with the existing native library. It runs one Flutter document probe, then two
independent CLI processes with three alternating-order trials per configuration.
Each process loads its own engine; loading and foreground setup are recorded or
excluded from the measured intervals. Allow several minutes for the complete run.
`--processes`, `--repetitions`, and `--modes` can narrow diagnostic follow-ups.

The Flutter probe measures the real `PaperSequence` and `MlsrNarrator` paths on
the supplied PDF, with no foreground speech and no mounted reader UI. It reports
indexing, reconstruction/extraction counts, admission, completion, metadata,
disposal, publication, and yields. A separate 100-read snapshot measurement is
outside the document interval. Failed passages remain explicitly counted with
errors; a completed diagnostic is not a claim that all passages are supported.

The first 24 extracted sentences of 35–220 UTF-16 units form a saved corpus.
The CLI groups this exact text into 24 one-sentence passages or three passages
of eight sentences, separated by newlines. It records model-segment count and
a hash of the actual segment texts. Only matching segments support a grouping
comparison independent of changed segmentation. Inference durations/predicted
audio lengths are not assumed equivalent solely from passage counts.

CLI modes `idle`, `playing`, and `paused` reproduce speech-state subscription
and completion waiting. Diagnostic modes `paused_unobserved`,
`paused_done_only`, and `paused_states_only` isolate observer effects while
retaining paused speech. Each foreground request reaches readiness before the
trial, and is cancelled/disposed afterwards. An idle trial has no speech handle.

`prepare_sdk.py` copies only the Dart SDK package and inserts checked timing
sites. The pinned SDK and native library stay unchanged. Worker records use
Dart's monotonic Timeline clock across isolates: enqueue → worker start → native
call return → caller delivery. Metadata calls uniquely identify duration jobs
in this probe; `sdkWait` also includes foreground completion observation.
Temporary-worker `sdkDispose` timings include isolate startup/dispatch separately
from native cleanup. Queue delays for concurrent operations overlap: **do not
sum all worker records into document wall time**. Parent document/passage spans
also overlap their children. `sdk_done` includes inference and scheduling; it is
not a measurement of device/kernel inference time.

Raw JSON, command logs, source/native hashes, PDF/text identities, and host power
and process snapshots remain in the evidence directory. These are active-host
diagnostics, not portable latency guarantees or a release UI benchmark. The
in-memory app trace is bounded and stores no source text; the explicitly exported
corpus contains document text. SDK records are also bounded and fail explicitly
if the diagnostic buffer fills.

## Observations on 2026-10-21

On this Apple Silicon Mac on AC power, with other host activity, the AOT probe
reproduced the passage-count sensitivity. Two independent processes, each with
three alternating-order repetitions, produced these medians. All cases used the
same 24 model segments, with identical segment-text hashes and the same M1 voice,
English locale, rate 1, eight steps and seed 0. Model loading and foreground
readiness were outside the interval.

| Speech activity | 24 short passages | 3 grouped passages |
| --- | ---: | ---: |
| No speech request | 65.98 ms | 62.97 ms |
| Playing, both observers | 2469.83 ms | 308.01 ms |
| Paused, both observers | 5085.56 ms | 543.07 ms |

For short passages during playback, the median duration-metadata operation waited
50.87 ms to enter the shared worker, then took 20 microseconds inside the native
operation (including serialization/decoding there). Paused, the corresponding
values were 108.87 ms and 38 microseconds. Completion retrieval and metadata
retrieval both queue behind the speech observers. Per-run disposal across all
24 passages took only about 3–4 ms in these observed-speech cases.

A third process retained the paused speech request but varied its observers:

| Paused-speech observers | 24-passage median, two alternating-order trials |
| --- | ---: |
| Neither | 68.70 ms |
| Completion wait only | 2608.03 ms |
| State subscription only | 2505.61 ms |

This isolates the large delay to blocking observation calls sharing the serial
Dart adapter. During playback, state polling can wake promptly as state changes;
when paused, both the state poll and completion wait can consume their timeout.
This explains the stronger paused case and why fewer passage-level round trips
help even when the number of model predictions stays constant. These results do
not identify device inference time or establish a post-fix performance guarantee.

The full ResNet PDF probe, using the unmodified prepared SDK and no foreground
speech, processed 389 passages in a median 2.21 seconds over its first three
passes (a subsequent independent process gave 2.27 seconds). Of these, 349 had
model timings and 40 failed with unsupported-character errors involving extracted
private-use/control characters. Those failures are retained explicitly, not
counted as successful inference. First-process median stage totals were about
164 ms for indexing, 134 ms for reconstruction, 78 ms for disposal, and 27 ms for
synchronous timing publication. There was no mounted reader UI, so widget/frame
costs are outside this document measurement. Native completion waiting still
combines preparation, inference, and scheduling.

This diagnosis motivated keeping blocking speech observation off the serial lane
used to deliver duration completion and metadata, while preserving handle
ownership, cancellation, and bounded observation; see the fix validation below. Passage merging would mask
this cost and alter document behavior; the evidence points to the SDK adapter.

Local raw evidence (ignored, retained on this checkout):

- `build/duration-profile/app-complete/app.json`: first full-document process.
- `build/duration-profile/sdk-probe/run-aot-{1,2}.json`: primary AOT comparisons.
- `build/duration-profile/observer-controls/process-0.json`: observer controls.
- `build/duration-profile/observer-controls/receipt.json`: end-to-end launcher
  verification, source/native hashes, command logs, and power/process snapshots.
- `build/duration-profile/summary.json`: consolidated numbers and evidence paths.

The initial test-runner PDFium discovery failure, the first full-document run
that stopped on its zero-failures assertion, and a plain `dart compile exe` launch
without native assets remain separately in the diagnostic directory. Successful
CLI builds use `dart build cli`; the PDF probe explicitly selects the prepared
PDFium library. These setup failures are not included in the timing table.

## Fix validation on 2026-10-21

PoDoFo now pins MLSR `0ca5d81bbcad0fa8a6274ebe3a7e44200bdc4da6`.
Completion waiting, state polling, and audio polling each use a persistent
adapter owned by that future or stream. Metadata retains the shared Tts adapter.
Every poll retains the existing lease accounting, and each polling adapter closes
in `finally` after the native call returns. Cancellation, coalescing, and stream
backpressure keep their existing contracts. This changes Dart scheduling only;
the prepared native library SHA-256 stayed
`ecc5b178a2d49fa2dda020773eefb714d160e277b0461308e6b689734f9ea19f`.

A fixed / original / fixed sequence of independent AOT processes reproduced the
improvement. The fixed processes each ran three alternating-order repetitions;
the intervening original process ran two. The same saved ResNet-derived corpus,
24 model segments and segment-text hashes were used throughout. Engines were
loaded and warmed before timing; foreground readiness was excluded. The original
executable retains its original Dart binding and native asset.

| Activity | Passages | Original control median | Fixed median |
| --- | ---: | ---: | ---: |
| No speech | 24 | 66.86 ms | 68.83 ms |
| No speech | 3 | 61.92 ms | 65.83 ms |
| Playing | 24 | 2473.55 ms | 71.94 ms |
| Playing | 3 | 303.89 ms | 64.77 ms |
| Paused | 24 | 5078.21 ms | 69.53 ms |
| Paused | 3 | 540.39 ms | 64.97 ms |

The 24-passage playing and paused workloads improved about 34x and 73x. Idle
changes are a few milliseconds; the extra worker lifecycle remains included,
and these active-host measurements do not establish an idle speed improvement.
The application PDF probe still reports unsupported extracted characters as
failures; this scheduling fix does not change text normalization or model support.

Validation included six real SDK tests (two unrelated model-delivery/export
cases skipped), 42 PoDoFo controller/timeline/lifecycle checks including two native
narration tests, SDK analysis, and preparation tests. The new SDK regression test
fails against the original binding: 64 sequential metadata reads with pending
completion/state observers took 6.96 seconds, exceeding its generous two-second
bound. It passes with the fix and also covers early disposal, error completion,
owner shutdown, and native handles returning to baseline. No new human listening
or reader-window acceptance is claimed by these automated checks.

Evidence remains under `build/duration-profile/`:

- `fixed-sdk/fixed-{1,2}.json`: the repeated fixed measurements.
- `sdk-probe/control-after-fix.json`: the intervening original-binding control.
- `sdk-probe/regression-before.log`: the expected regression-test failure.
- `fix-app-tests.log`: the 42 passing PoDoFo checks.
- `fixed-integrated/`: the final end-to-end run with the pinned SDK.
- `fix-summary.json`: consolidated comparison and verified source hashes.

`run.py --sdk-source /path/to/MLSR/bindings/dart` can select another Dart package
for the isolated CLI comparison. The application PDF probe always uses PoDoFo's
prepared SDK. The CLI trace records isolate debug names and includes `sdk.dart`
in source hashes, distinguishing metadata, completion, state, and audio workers.
The new SDK revision is currently local to `fix/dart-observation` in
`/Users/yunhocho/GitHub/MLSR-dart-observation`; it has not been published remotely.
