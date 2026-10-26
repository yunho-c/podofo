# Podoco documentation

- [Development](development.md): setup, builds, checks, and generated files.
- [Rust contracts (M1)](contracts.md): validated inputs/results, image ownership,
  bounded JSON, and offline bundle verification.
- [Layout inference (M2)](layout.md): blocking Rust sessions and the PNG CLI.
- [C ABI](ffi.md): current exported functions and ownership guarantees.
- [Core ML](coreml.md): optional native dependency, observer policy, and checks.
- [Dart package](../bindings/dart/README.md): native builds and prebuilt libraries.
- [Architecture](internal/architecture.md): ownership and planned boundaries.
- [Proposed API v0](../../docs/podoco-api.md): document/formula analysis, image
  leases, progressive jobs, and optional math-to-speech-text conversion.
- [Implementation plan](../../docs/podoco-implementation.md): independently
  testable milestones using PP-DocLayoutV3 and PP-FormulaNet_plus-L.
- [Validation scope](internal/validation.md): what the scaffold checks establish.
- [cidre coexistence](internal/cidre-coexistence.md): observer exclusion and
  namespacing experiments for loading Podoco alongside MLSR.

M1 implements Rust data/ownership contracts and offline verification. M2 adds
Core ML layout inference. Document jobs and C/Dart analysis APIs remain planned. The concrete
PP-DocLayoutV3 bundle remains experimental, not production-qualified.
