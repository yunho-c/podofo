# Podoco

A Rust-first library for efficient document analysis with ergonomic language
bindings. Podoco lives alongside the PoDoFo application in this Git repository,
with its own Cargo workspace and development checks.

**Status: initialized scaffold.** Rust, C, and Dart expose library identity;
the Dart package builds and bundles the native library for desktop host builds.
Model loading, inference, OCR, layout detection, reading order, and table
recognition are not implemented. Core ML via cidre is the selected first backend;
QNN is planned for Qualcomm Windows targets. PP-DocLayoutV3 is selected for layout
detection; formula-recognition model selection is ongoing.
An optional [Core ML dependency](docs/coreml.md) is wired with observer exclusion
and a real-model coexistence check; the document-analysis runtime remains future work.
The packages are private while the first analysis contract is established.

## Quick start

From this directory, with stable Rust, Python 3.11+, and a native C toolchain:

```sh
python3 tools/dev.py build
cargo run --locked -p podoco --example version
```

For Dart, use the existing Dart SDK (local validation uses Dart 3.13.5):

```sh
cd bindings/dart
dart pub get --enforce-lockfile
dart run example/version.dart
```

Both examples report `Podoco 0.1.0`. Dart checks C ABI compatibility before
reading the native version. No model weights are needed or downloaded.

## Layout

```text
Cargo.toml             Podoco's Cargo workspace, independent of the app
crates/podoco/          Public Rust API and future analysis implementation
crates/podoco-ffi/      Shared C ABI adapter; dynamic and static libraries
include/podoco.h        Generated C header
bindings/dart/         Dart API, generated FFI, and native build hook
model-manifests/        Model contract policy; no model is selected yet
examples/              Index of executable examples
tests/integration/     Actual C caller checks
third_party/cidre/     Pinned MIT-licensed Apple bindings with observer exclusion
tools/codegen/         Pinned C header generator
tools/dev.py           Build, generation, and validation commands
docs/                  Consumer setup and API contracts
docs/internal/         Maintainer architecture and validation scope
```

Rust callers depend directly on `podoco`. Other languages use `podoco-ffi`.
PoDoFo will consume the public Dart package; no application dependency is added
by this scaffold. A Flutter-specific adapter belongs under `bindings/flutter/`
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
