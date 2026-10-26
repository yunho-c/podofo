# Rust document jobs

`Analyzer` runs bounded, eager document jobs through the same PP-DocLayoutV3
pipeline as [`LayoutSession`](layout.md). Sources render lazily and every job
requires a serial update sink. Calling `wait()` completes without subscribing
to progress. Open both verified bundles with `Analyzer::open_with_formula` to
recognize PP-DocLayoutV3 detections using PP-FormulaNet_plus-L. The combined
profile remains experimental; layout-only analyzers require `FormulaScope::None`.

## Run a document

Prepare the v1 layout bundle as described in the [layout guide](layout.md), then:

```sh
cargo build --release --locked -p podoco --features coreml --example document_layout
target/release/examples/document_layout \
  model-assets/layout-v1 cpu-ne 64000000 96000000 2000000 1000000 2 \
  page-1.png page-2.png > updates.jsonl 2> outcome.json
```

Arguments are bundle, compute policy, input bytes, tensor bytes, total pending
result bytes, maximum update bytes, pending update count, and PNG pages. These
are example limits, not recommended rendering resolutions or production defaults.
Each stdout line is an `AnalysisUpdate`; stderr contains the authoritative
`AnalysisOutcome`. The process exits unsuccessfully for partial, cancelled, or
failed work. Files must remain immutable while the example runs. Its coordinates
are image pixels; a PDF source supplies canonical page dimensions and its own map.

The [complete example](../crates/podoco/examples/document_layout.rs) implements
`PageSource`, inspects only headers before submission, decodes on demand, and
writes updates as the sink accepts them. PNG decoding and the sink's own JSON
buffer are caller storage, separate from SDK reservations.

For progressive formula recognition, prepend
`--formula FORMULA_BUNDLE TOKEN_CAP CACHE_BYTES` to those arguments. For example:

```sh
target/release/examples/document_layout \
  --formula model-assets/formula-v1 2048 50331648 \
  model-assets/layout-v1 cpu-ne 16777216 134217728 4194304 2097152 2 \
  page-1.png page-2.png > updates.jsonl 2> outcome.json
```

Use `Analyzer::profile()` when constructing `AnalysisOptions`: the combined
profile differs from each bundle's profile and includes any lower token cap.
`PageLayoutReady` exposes pending formula IDs, each `FormulaFinished` supplies
one owned outcome, and `PageFinished` contains the final snapshot. Both bundles
remain loaded across jobs; each formula starts with fresh decoder state.
Cancellation is checked between decoder predictions and preserves acknowledged
results. Formula decoding errors/truncation remain explicit in the final status.

The combined pipeline requires at least **96 MiB tensor bytes** and **40,108,032
decoder-cache bytes**. Each active stage reserves 32 MiB for the inactive
session's retained host/tensor storage. The example gives additional scratch
space and larger bounded updates for pages with many formulas and their full
provenance. Core ML weights/workspaces are outside these SDK-visible limits.
All stages currently use the same explicit compute policy. A progressive page's
provenance lists both configured models before recognition runs; each recognized
formula records its own recognizer provenance. Include all model hashes, the
effective analyzer profile and compute policy in persistent cache identities.

## Ownership and scheduling

1. Open an analyzer with a verified bundle and explicit `AnalyzerOptions`.
2. Implement `PageSource`: immutable document/revision, ordered unique page
   descriptors, and `load_page(PageRequest)` on the source worker. Metadata
   accessors must be cheap and must not render.
3. Call `analyze_document(source, options, sink)`. It snapshots metadata, checks
   capabilities/profile, and admits the job to a bounded FIFO queue. A full queue
   returns `LimitExceeded` without rendering. IDs are independent random 128-bit
   values, including retries.
4. Keep the returned `AnalysisJob`; its work starts eagerly. Use `cancellation()`
   for a cloneable control handle, `progress()` for an optional snapshot, and
   `wait()` for completion.
5. Call idempotent `job.close()` and `analyzer.close()` to cancel unfinished work
   and wait for cleanup. Drop also cancels and waits.

There is one active job/page and no speculative prefetch. The queued-job limit
excludes the active job. Queued sources own metadata/callback state but are never
asked to render. The next job starts after the current job's source and sink
callbacks drain, preserving the analyzer-wide input/result limits. Each active
job has a source worker and a delivery worker; the analyzer scheduler uses the
safe session handle. Native models and tensors stay on M2's persistent owner
thread throughout. No native object is made `Send` or moved across threads.

`analyze_page` uses a descriptor and a lazy one-shot loader with the same job
semantics. Use `LayoutSession` for already-rendered blocking single-page calls.
The lazy interface prevents queued input rasters from escaping the byte budget.

## Budgets and backpressure

The scheduler reserves the full input budget before calling the source. The
request includes that budget, the exact page descriptor, a cancellation handle,
and white-background/BGRA preference. RGBA remains accepted. The source chooses
resolution using its qualified render profile and must honor the reservation.
Actual retained bytes, including row padding/trailing allocation, are checked
on return. The SDK rejects oversize images; it cannot prevent a caller from
allocating too much before returning. A cancellation reservation remains charged
until the renderer returns and its late image is released.

Pending updates are stored as bounded serialized buffers. Limits count buffer
capacity, the currently executing sink call, and a maximum-update reservation
taken before encoding. This conservative reservation can apply backpressure
before the actual serialized bytes fill the total limit. Count and byte limits
both apply. The delivery worker decodes one owned update and drops its encoded
buffer before invoking the sink, retaining its charge until acknowledgement.

These counters are not process-memory caps: they exclude source/sink-owned
storage, immutable document metadata, the active page graph, one decoded sink
argument, allocator metadata, and Core ML's opaque allocations described in the
[layout guide](layout.md). A sink that keeps accepted results must bound/store
them itself. The SDK retains counts and the final outcome, not every page graph.

Layout-only processing releases the source image before waiting for result
capacity. Cancellation, source release, and shutdown flags use a separate
control path; they do not need a result-queue slot or sink acknowledgement.

## Results, failures, and cancellation

Layout-only pages emit `PageLayoutReady` then authoritative `PageFinished`,
followed by a document processing notice. Formula regions have `NotRequested`
states. Update sequences increase monotonically within the run. Cancellation
can discard pending content, so the delivered sequence may contain gaps;
already acknowledged updates remain valid. A healthy sink can still receive
`DocumentFinished` after cancellation.

`AnalysisOutcome` is authoritative after all callbacks drain. Its `summary`
describes processing; `delivered` separately counts acknowledged updates,
page/formula snapshots, the last sequence, and the terminal notice. A sink that
fails on `DocumentFinished` yields an overall failed outcome even if processing
completed successfully. Sink errors and panics stop delivery and request source
cancellation. A terminal notice that exceeds its budget also fails completion.

Recoverable page-source/layout errors emit `PageFailed` and allow later pages;
the final status is partial. A changed source revision, callback panic, fatal
native error, invalid pipeline result, or delivery failure ends the job. A native
pipeline failure or panic closes the analyzer and fails queued jobs without
rendering; create a new analyzer to recover. Source/sink failures alone do not
invalidate an otherwise healthy model.

Cancellation is cooperative. Sources should check their token and finish
promptly; late returned images are released without prediction. An in-flight
Core ML prediction finishes before its input lease is released. Arbitrary
blocking caller code cannot be interrupted, so a callback that never returns
can delay `wait`/`close`, including queued jobs behind it. Sink/source callbacks
run outside SDK locks. They may request cancellation but must not wait for or
close jobs owned by their analyzer; those waits return `InvalidInput` to avoid
self-deadlock. Keep blocking construction/wait/close off UI and executor threads.

[M3 validation](internal/m3-validation.md) records lifecycle tests and real-model
comparison. [C/Dart transport](ffi.md) is implemented in M4; model promotion and recognition
quality remain separate gates.
