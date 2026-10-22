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

The next targeted fix is to keep blocking speech observation off the serial lane
used to deliver duration completion and metadata, while preserving handle
ownership, cancellation, and bounded observation. Passage merging would mask
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
