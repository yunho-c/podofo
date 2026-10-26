# Podoco documentation

- [Development](development.md): setup, builds, checks, and generated files.
- [C ABI](ffi.md): current exported functions and ownership guarantees.
- [Core ML](coreml.md): optional native dependency, observer policy, and checks.
- [Dart package](../bindings/dart/README.md): native builds and prebuilt libraries.
- [Architecture](internal/architecture.md): ownership and planned boundaries.
- [Validation scope](internal/validation.md): what the scaffold checks establish.
- [cidre coexistence](internal/cidre-coexistence.md): observer exclusion and
  namespacing experiments for loading Podoco alongside MLSR.

There is no document analysis API or supported model yet. The architecture
describes the intended direction without claiming inference support.
