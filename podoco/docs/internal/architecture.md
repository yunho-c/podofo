# Architecture

Podoco is an independent document analysis SDK inside PoDoFo's Git repository.
Its Rust workspace is rooted at `podoco/Cargo.toml`. Sharing a repository allows
atomic library/application changes; Podoco must remain usable by other clients.

The [proposed API v0 contract](../../../docs/podoco-api.md) records the agreed
document/formula pipeline, image ownership, progressive jobs, and optional math
conversion. M1 implements the [Rust data/ownership contracts](../contracts.md)
and offline model verification. M2 adds a [blocking layout session](../layout.md),
private page pipeline, and thread-confined Core ML runtime. M3 adds
[bounded document jobs](../jobs.md). M4 implements [C transport](../ffi.md)
and the [typed Dart SDK](../../bindings/dart/README.md). M6 adds PP-FormulaNet_plus-L
to the same bounded job lane. M7 provides isolated optional math workers; M8
qualifies renderer-owned image leases. M9 connects progressive Copy/Listen in
PoDoFo, with model quality and human acceptance tracked separately.

## Dependency direction

```text
Rust consumers -------------------------> podoco
PoDoFo / other Dart clients -> Dart API -> podoco-ffi -> podoco
```

The core provides validated domain types, image copying, bounded JSON results,
and local bundle verification. C handles and Dart pumps translate foreign
ownership, lazy source requests, bounded result delivery, and control notifications. The optional `coreml` feature implements layout and formula
inference, with Rust-owned scheduling in `jobs`. PDF rendering remains the
caller's responsibility.

The selected backend direction is Core ML via cidre first, followed by QNN for
Qualcomm Windows targets. The [cidre coexistence investigation](cidre-coexistence.md)
provides tested observer-exclusion and namespacing candidates for native
packaging alongside MLSR. The pinned cidre dependency adopts observer exclusion;
namespacing remains a fallback if KVO is later needed. See [Core ML setup](../coreml.md).

## Responsibilities

| Layer | Intended ownership |
| --- | --- |
| Public Rust API | Validated requests, analysis lifecycle, cancellation, results, and errors |
| Model pipelines | Model-specific preprocessing, execution sequence, and postprocessing |
| Runtime adapters | Persistent model sessions, tensors, device policy, and backend execution |
| C ABI | Foreign ownership, handles, layouts, error translation, and panic containment |
| Dart binding | Idiomatic Dart types and lifetime translation over the shared Rust contract |
| PoDoFo | PDF session/rendering integration, user interaction, display, navigation, and application persistence |

Start model pipelines and runtimes as modules inside `podoco`. Extract crates
when dependencies, platform builds, or actual reuse justify a boundary. Avoid
an abstract universal tensor engine before the first concrete model contract.

For the first integration, prefer portable page images and optional extracted
text/geometry at the library boundary. This lets PoDoFo reuse its existing PDF
engine and lets other callers supply scans or rendered pages. A future
file-level convenience API can compose a separate document-loading adapter.
Do not move PoDoFo's PDF resource ownership into the core by accident.

Results should preserve page identity and explicit coordinate conventions,
including transforms between model input pixels and source-page geometry.
Reading order and text provenance need explicit contracts before they drive
selection, navigation, or narration. The API proposal defines canonical page
coordinates and proposed result types; no public analysis ABI is frozen yet.

## Efficiency and qualification

The first model slice should reuse loaded sessions and buffers, bound queued
pages and retained results, define cancellation checkpoints, and make copies
and ownership across the ABI explicit. Device choices must expose actual
backend availability rather than silently imply hardware acceleration.

Measure cold loading separately from warm analysis. Report complete request
time, peak memory, and output quality on pinned inputs; device/kernel timing
alone does not establish application throughput. Retain reference outputs and
coordinate/reading-order checks alongside model-specific quality metrics.

## Application integration and remaining gates

M1–M8 establish domain/ownership contracts, real model execution, bounded jobs,
C/Dart APIs, [PoDoFo rendering and persistence](../../../docs/document-analysis.md),
and optional MathCAT conversion. The app now merges progressive formula results
into its own immutable snapshots, caches both model identities and compute policy,
and owns whole-equation selection and playback intent. Caller identity in the
shared narrator prevents stale equation work from cancelling a newer prose request.

The [implementation plan](../../../docs/podoco-implementation.md) gives the
concrete dependency order and completion gates. PP-DocLayoutV3 is selected for
layout and PP-FormulaNet_plus-L for recognition. Their pinned conversions and
native parity are recorded alongside corpus accuracy limits. M9 automated
integration, model-profile promotion, and human listening acceptance are separate
claims; see the [integration report](m9-integration-validation.md).
The queued, cancellable [explicit-crop API](../formula.md#queued-explicit-crops)
shares the document job lane across Rust/C/Dart. It preserves caller page/region
identity without invoking layout, and drains foreign image releases before the
next queued renderer. Direct Rust callers can also use `FormulaSession` with
their own scheduling.
