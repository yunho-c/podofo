# Validation scope

M3 adds bounded Rust document jobs; see [M3 validation](m3-validation.md).
M2's layout integration is recorded in [M2 validation](m2-validation.md).
The records below describe earlier milestones, not the current runtime surface.

M1 adds portable contracts, ownership tests, result-schema fixtures, local bundle
verification, and small eager-reference captures. Its specific evidence is
recorded in [M1 validation](m1-validation.md); the initialization and Core ML
dependency records below remain historical evidence for their own boundaries.

The development checks exercise Rust library identity, the generated C ABI, and
the Dart native-asset build/load path. A copied Dart package uses a relocated
prebuilt native library without access to the checkout's Rust sources.

## Local initialization check: 2026-10-25

Passed on macOS 27.0.1, arm64, using Rust 1.95.0, Dart 3.13.5, and Python 3.14.8:

- `python3 tools/dev.py check`: Rust formatting, Clippy, unit/doc tests,
  documentation, generated header freshness, a compiled C caller, Dart
  formatting/analysis/tests, and relocated-package loading. The relocated
  package also rejected an intentionally incompatible ABI 2 library.
- `python3 tools/dev.py check-generated`: exact C and Dart generation checks.
- `cargo +1.88.0 test --locked -p podoco -p podoco-ffi --target-dir target/msrv`:
  production crates and Rust API documentation on the declared minimum Rust.
- Ruff checks for the development script, actionlint for the new workflow,
  and local Markdown link validation.

## Core ML dependency adoption: 2026-10-25

On the same macOS arm64 host:

- `tools/check_coreml.py --mlsr-library ...` passed eight fresh-process loading
  cases with 56 inference-probe calls and 168 CPU-only affine predictions. Both
  loading orders passed for release, debug, and `-ObjC` observer-disabled probes
  beside an observer-enabled control, plus the existing MLSR dylib. Symbol checks
  confirmed the Core ML bridge was linked and the disabled helper was absent.
- The complete default Rust/C/Dart check passed again, along with Clippy and
  Rust tests with `coreml` enabled. Rust 1.88 built the Core ML probe and passed
  the production crates' tests with that feature enabled.
- An external Rust application using both Podoco and MLSR built and ran with
  the documented root override; its resolved graph contained one patched cidre
  and did not enable the observer feature.
- The vendored tree reproduced exactly from the checksum-verified published
  archive, the recorded patch, and upstream license. Per-file verification is
  included in the standard development check and CI.

The [adoption result](../../tools/cidre_coexistence/adoption-qualification.json)
records artifact hashes; detailed logs remain under ignored
`evaluation-output/coreml-adoption-20261025-final/`. The broader
[candidate investigation](cidre-coexistence.md) separately qualifies namespacing,
KVO lifecycle, and expected collision controls. This dependency milestone does
not implement document inference in Podoco's public API.

## Remaining qualification

CI is configured for macOS, Linux, and Windows host builds, generated C/Dart
freshness, production-crate tests on Rust 1.88, and macOS Core ML coexistence.
Configuration alone does not
establish that those remote jobs have passed.

Document-model inference, quality, performance, Flutter application integration, mobile,
web, cross-compilation, and published package distribution are outside this
initialization's validation scope. The Rust ABI emits a static library too,
but the Dart hook only bundles dynamic libraries.
