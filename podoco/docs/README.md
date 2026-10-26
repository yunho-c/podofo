# Podoco documentation

- [Development](development.md): setup, builds, checks, and generated files.
- [C ABI](ffi.md): current exported functions and ownership guarantees.
- [Core ML](coreml.md): optional native dependency, observer policy, and checks.
- [Dart package](../bindings/dart/README.md): native builds and prebuilt libraries.
- [Architecture](internal/architecture.md): ownership and planned boundaries.
- [Proposed API v0](../../docs/podoco-api.md): document/formula analysis, image
  leases, progressive jobs, and optional math-to-speech-text conversion.
- [Implementation plan](../../docs/podoco-implementation.md): independently
  testable milestones with PP-DocLayoutV3 selected and the recognizer pending.
- [Validation scope](internal/validation.md): what the scaffold checks establish.
- [cidre coexistence](internal/cidre-coexistence.md): observer exclusion and
  namespacing experiments for loading Podoco alongside MLSR.

There is no implemented document analysis API or qualified Podoco model bundle
yet. Selecting PP-DocLayoutV3 does not by itself establish inference support.
