# Architecture

Podoco is an independent document analysis SDK inside PoDoFo's Git repository.
Its Rust workspace is rooted at `podoco/Cargo.toml`. Sharing a repository allows
atomic library/application changes; Podoco must remain usable by other clients.

## Dependency direction

```text
Rust consumers -------------------------> podoco
PoDoFo / other Dart clients -> Dart API -> podoco-ffi -> podoco
```

The initial core exposes library identity only. The C ABI and Dart native hook
are executable plumbing, not a substitute for a real analysis implementation.
No model, inference runtime, PDF parser, or GPU/NPU dependency is included.

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
selection, navigation, or narration. No such result types are frozen yet.

## Efficiency and qualification

The first model slice should reuse loaded sessions and buffers, bound queued
pages and retained results, define cancellation checkpoints, and make copies
and ownership across the ABI explicit. Device choices must expose actual
backend availability rather than silently imply hardware acceleration.

Measure cold loading separately from warm analysis. Report complete request
time, peak memory, and output quality on pinned inputs; device/kernel timing
alone does not establish application throughput. Retain reference outputs and
coordinate/reading-order checks alongside model-specific quality metrics.

## Next implementation milestone

Select one document-analysis task and model, define its inputs/results, pin a
YAML manifest with license and hashes, and capture reference cases. Implement
one complete Rust-owned pipeline with a real runtime, cancellation, and a Dart
consumer. It is done when real inputs produce qualified outputs through the
public APIs; a placeholder `analyze` method would not meet that gate.
