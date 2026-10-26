# Blocking Rust layout inference

`LayoutSession` analyzes raw page images with PP-DocLayoutV3 on macOS through
Core ML. The experimental v1 profile returns canonical page-space boxes, native
labels/subtypes, scores, and reading order. Detected formulas carry inline or
displayed context and `NotRequested` recognition states. Formula recognition and
polygons are not yet available. PP-FormulaNet_plus-L is the selected recognizer
for the next model milestone.

## Prepare and run

Use the existing local export/checkpoint roots from the [offline bundle guide](../tools/pp_doclayout_v3/README.md).
Prepare a new directory using `model-manifests/pp-doclayout-v3-coreml-v1.yaml`:

```sh
cargo run --locked -p podoco --example model_bundle -- prepare \
  model-manifests/pp-doclayout-v3-coreml-v1.yaml \
  /path/to/export /path/to/checkpoint model-assets/layout-v1

cargo run --release --locked -p podoco --features coreml --example page_layout -- \
  model-assets/layout-v1 cpu-ne 64000000 96000000 2000000 \
  page-1.png page-2.png > pages.jsonl 2> report.json
```

For a clean JSON diagnostic file, build the example first, then invoke
`target/release/examples/page_layout` with the same arguments. Cargo otherwise
adds its build messages to stderr. Each stdout line is one final `PageAnalysis`;
stderr contains verification/opening and per-page timing/counter observations.

The positional arguments are bundle directory, compute policy (`cpu`, `cpu-ne`,
`all`), input-byte budget, tensor-byte budget, maximum JSON-result bytes, and one
or more PNG files. Those example budgets are explicit demonstration settings,
not model-quality or production-memory defaults. PNG decoding lives entirely
in the example. Its pages use pixel units with an identity map; a PDF caller
supplies its own page dimensions and pixel-to-page transform.

M2 loads the verified compiled `.mlmodelc`. It does not download, compile, or
repair incompatible artifacts. Keep payloads, including symlink targets,
immutable after verification. Native load failures preserve owned diagnostics;
a structurally valid manifest alone does not prove an executable model.

## Session contract

1. Verify local assets with `ModelBundle::verify`.
2. Open with `LayoutSession::open(bundle, AnalyzerOptions { compute_policy, limits })`.
3. Construct `AnalysisOptions` with the bundle's exact profile ID and explicitly
   set `formula_scope = FormulaScope::None`.
4. Call `analyze_page(&mut self, PageInput, AnalysisOptions)` for each page.
5. Read `stats()` as needed, then call idempotent `close()`.

Opening and analysis block. Keep these calls off UI and async executor threads.
A dedicated worker creates, uses, and releases all native objects. The session
is not cloneable, and mutable access serializes requests through one bounded
channel. The model, input tensor/provider, preprocessing rows, and small output
buffers are retained across calls. Results own no image or native references.
Drop joins the worker, as does explicit close.

Invalid options, oversized input, invalid premultiplied pixels, decoding errors,
and result-budget rejection leave the session usable. A native exception or
prediction failure terminates native state; a later request returns
`WorkerFailed`. A worker panic unblocks callers with `WorkerFailed`. Analysis
after ordinary close returns `InvalidInput`. A running native prediction cannot
be interrupted by this blocking API; document-job cancellation is M3 work.

## Pixels and decoding

BGRA8/RGBA8 input may include row padding. Straight alpha is composited over
white with integer rounding; valid premultiplied pixels are composited directly.
Premultiplied colors exceeding alpha are rejected, including pixels skipped by
resampling. Opaque mode ignores alpha.

The resize ports the pinned native uint8 bicubic path: quantized coefficients,
clamped borders, horizontal then vertical rounding/clipping, no antialiasing,
and Float32 division by 255 into RGB NCHW `[1,3,800,800]`. Four reusable rows
avoid a full-resolution intermediate. Exact tensor comparisons cover the
synthetic fixtures and all 50 retained qualification pages.

The v1 profile selects sigmoid top-300 query/class pairs, then keeps scores
`>= 0.30`. Equal candidate scores use query ID then class ID. Reading order
uses the pinned Float32 vote reduction, with query-ID ties and class-ID order
for multiple retained classes from one query. Region IDs are `query*25+class`,
so they do not depend on sorting position; they are local to one page/run.

No extra NMS, deduplication, or polygon output is added. All four box corners
are mapped into page space; finite out-of-page boxes are preserved. Crop
clamping is a separate geometry operation. Invalid selected geometry fails the
page. Provenance includes the actual verified manifest/payload hashes and the
v1 adapter/profile. v0 remains verifiable for M1 reproduction but cannot open a
runtime session.

## Memory and evidence

Input limits count the entire retained image allocation. Tensor limits include
host input/small-output storage, native input and all exported output spans,
and a 128 KiB allowance for interpolation/decoding scratch. Native strides can
increase the actual span beyond logical tensor sizes. Known minimum sizes are
checked before opening; returned spans are checked after prediction. The mask
export alone has 48,000,000 logical bytes, even though normal Rust inference
only inspects its metadata and never reads/copies its contents.

These limits do not cap Core ML's opaque model weights, compiler/device caches,
or internal workspace. A returned-span rejection cannot undo an allocation
already made by Core ML. `peak_tensor_bytes` reports checked spans plus the
scratch allowance, not measured physical allocation. `host_buffer_bytes` counts
persistent preprocessing/input/small-output buffers. Result serialization is
bounded before publishing a snapshot; caller-owned inputs/results and example
PNG decoding are separate from these internal budgets.

Stage timing distinguishes preprocessing, native input write/prediction/small
readback, decoding, and the complete blocking call. Open excludes earlier bundle
verification; the example separately records it. Compute policy grants device
permission and is not evidence of ANE placement.

The [M2 qualification record](internal/m2-validation.md) distinguishes exact Rust
integration parity from existing export-to-eager differences. The mixed model
remains experimental: two known extra detections and differing order pairs
still require investigation before production promotion. macOS arm64 is the
qualified host; iOS and minimum-OS execution have not been demonstrated.
