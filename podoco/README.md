# Podoco

A Rust-first library for efficient document analysis with ergonomic language
bindings. Podoco lives alongside the PoDoFo application in this Git repository,
with its own Cargo workspace and development checks.

**Status: M5 app layout, M6 formula analysis, and M7 optional math conversion implemented.** Rust provides checked
page images, portable results, offline model bundles, and reusable Core ML
`LayoutSession` execution for PP-DocLayoutV3. `Analyzer` adds eager document jobs,
lazy rendering, bounded sinks, and cancellation. See [document jobs](docs/jobs.md),
[layout inference](docs/layout.md), and [Rust contracts](docs/contracts.md). The mixed-precision model profile remains
experimental; its known export differences are recorded in the qualification.

The [C ABI](docs/ffi.md) and [Dart SDK](bindings/dart/README.md) expose document
jobs, copied images, controlled native leases, typed results, and draining
cancellation. PoDoFo now has an [experimental layout integration](../docs/document-analysis.md).
PP-FormulaNet_plus-L has a [qualified blocking Rust crop recognizer](docs/formula.md).
Its [progressive document pipeline](docs/internal/m6-document-validation.md) is also
qualified against the deployed reference; detector recall and recognition quality
limits remain explicit. [Optional math conversion](docs/math.md) exposes isolated
MathML/plain-speech workers through Rust/C/Dart. Renderer leases and Copy/Listen
are the next milestones.
Core ML via cidre is the first backend, with QNN planned for Qualcomm Windows.
[Observer exclusion and coexistence](docs/coreml.md) remain the packaging policy.
The packages are private while the complete analysis contract is established.

## Quick start

From this directory, with stable Rust, Python 3.11+, and a native C toolchain:

```sh
python3 tools/dev.py build
cargo run --locked -p podoco --example version
cargo run --locked -p podoco --example contracts
```

For Dart, use the existing Dart SDK (the M6 native run uses Dart 3.13.4):

```sh
cd bindings/dart
dart pub get --enforce-lockfile
dart run example/version.dart
```

The version examples report `Podoco 0.1.0`; `contracts` demonstrates copied-image
construction and bounded result serialization without inference. Dart checks C
ABI compatibility before reading the native version. No model weights are needed
or downloaded. [Offline model preparation](tools/pp_doclayout_v3/README.md) is explicit.

## Layout

```text
Cargo.toml             Podoco's Cargo workspace, independent of the app
crates/podoco/          Public Rust API, model pipelines, and runtime
crates/podoco-ffi/      Shared C ABI adapter; dynamic and static libraries
include/podoco.h        Generated C header
bindings/dart/         Dart API, generated FFI, and native build hook
model-manifests/        Pinned experimental layout and formula YAML contracts
examples/              Index of executable examples
tests/integration/     Actual C caller checks
third_party/cidre/     Pinned MIT-licensed Apple bindings with observer exclusion
tools/codegen/         Pinned C header generator
tools/dev.py           Build, generation, and validation commands
tools/pp_doclayout_v3/  Original fixture generation and offline reference tooling
tools/pp_formulanet/    Offline formula preparation and deployment qualification
docs/                  Consumer setup and API contracts
docs/internal/         Maintainer architecture and validation scope
```

Rust callers depend directly on `podoco`. Other languages use `podoco-ffi`.
PoDoFo consumes the public Dart package through its analysis adapter. A reusable
Flutter-specific adapter belongs under `bindings/flutter/`
when it has concrete model/resource integration to own. Additional language
bindings can use the same C ABI.

## Development

Run from this directory:

```sh
python3 tools/dev.py check
python3 tools/dev.py check-generated
```

The first command checks Rust formatting, Clippy, tests, API documentation,
header freshness, a compiled C caller, Dart analysis/tests, and a relocated Dart
package using a prebuilt library, including incompatible-ABI rejection. The
second also regenerates Dart bindings in
a temporary output location and compares them to the checked-in version; it
requires libclang. See [development](docs/development.md) for individual commands
and [validation scope](docs/internal/validation.md) for platform boundaries.

## License

Apache-2.0, matching the repository. See [LICENSE](LICENSE). The vendored cidre
dependency retains its [MIT license](third_party/cidre/LICENSE.txt). Future model weights
retain their own licenses and provenance, recorded separately in YAML manifests.
