# Examples

Run these from `podoco/`:

- [Rust identity](../crates/podoco/examples/version.rs):
  `cargo run --locked -p podoco --example version`.
- [Rust contracts](../crates/podoco/examples/contracts.rs):
  `cargo run --locked -p podoco --example contracts` (no model required).
- [PNG layout inference](../crates/podoco/examples/page_layout.rs): real sequential
  page analysis through one session; [setup and arguments](../docs/layout.md).
- [Offline bundles](../crates/podoco/examples/model_bundle.rs): local verification
  and preparation; [instructions](../tools/pp_doclayout_v3/README.md).
- [Dart identity](../bindings/dart/example/version.dart): run `dart run
  example/version.dart` from `bindings/dart/` after installing locked dependencies.

Dart analysis APIs arrive in M4. `coreml_probe` is a development-only library for
native coexistence checks, not an application C ABI.
