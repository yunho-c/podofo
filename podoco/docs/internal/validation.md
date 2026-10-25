# Scaffold validation scope

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

## Remaining qualification

CI is configured for macOS, Linux, and Windows host builds, generated C/Dart
freshness, and production-crate tests on Rust 1.88. Configuration alone does not
establish that those remote jobs have passed.

Model inference, quality, performance, Flutter application integration, mobile,
web, cross-compilation, and published package distribution are outside this
initialization's validation scope. The Rust ABI emits a static library too,
but the Dart hook only bundles dynamic libraries.
