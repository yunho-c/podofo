# Podoco documentation

- [Development](development.md): setup, builds, checks, and generated files.
- [Rust contracts (M1)](contracts.md): validated inputs/results, image ownership,
  bounded JSON, and offline bundle verification.
- [Layout inference (M2)](layout.md): blocking Rust sessions and the PNG CLI.
- [Document jobs (M3)](jobs.md): eager analysis, lazy sources, budgets, and cancellation.
- [PoDoFo integration (M5)](../../docs/document-analysis.md): rendering, cache, and reader controls.
- [C ABI](ffi.md): current exported functions and ownership guarantees.
- [Core ML](coreml.md): optional native dependency, observer policy, and checks.
- [Dart package](../bindings/dart/README.md): native builds and prebuilt libraries.
- [Architecture](internal/architecture.md): ownership and planned boundaries.
- [Proposed API v0](../../docs/podoco-api.md): document/formula analysis, image
  leases, progressive jobs, and optional math-to-speech-text conversion.
- [Implementation plan](../../docs/podoco-implementation.md): independently
  testable milestones using PP-DocLayoutV3 and PP-FormulaNet_plus-L.
- [Validation scope](internal/validation.md): milestone evidence and platform limits.
- [cidre coexistence](internal/cidre-coexistence.md): observer exclusion and
  namespacing experiments for loading Podoco alongside MLSR.

M1 implements Rust data/ownership contracts and offline verification. M2 adds
Core ML layout inference; M3 adds bounded document jobs. M4 exposes the
[C/Dart layout SDK](internal/m4-validation.md); M5 integrates the reader. The concrete
PP-DocLayoutV3 bundle remains experimental, not production-qualified.
