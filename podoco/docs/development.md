# Development

Work in `podoco/`, or pass `--manifest-path podoco/Cargo.toml` to Cargo from the
repository root. This directory owns the workspace, lockfile, and build output.
It is part of the existing Git repository, not a nested repository or submodule.

## Prerequisites

- Stable Rust with rustfmt and Clippy. Production crates declare Rust 1.88 as
  their minimum; the directory's toolchain file selects stable for development.
- A native C toolchain. The C smoke test uses `CC` or `cc` on Unix, and GCC/MinGW
  on Windows alongside Rust's MSVC toolchain. `CC` must name one executable.
- Python 3.11+ for the standard-library-only development script; no virtual
  environment or Python package installation is needed.
- Dart 3.13+ for binding checks. Local validation uses Dart 3.13.5, matching
  PoDoFo's current Dart SDK series.
- libclang only when regenerating or verifying the generated Dart bindings.
  Install `libclang-dev` on Debian/Ubuntu. If discovery fails, set
  `LIBCLANG_PATH` to the full path of the libclang shared library.

## Commands

```sh
python3 tools/dev.py build             # Rust native libraries
python3 tools/dev.py check             # Rust, C, Dart, relocated package
python3 tools/dev.py test-c            # Build and exercise C ABI
python3 tools/dev.py test-dart         # Host native-asset build and Dart checks
python3 tools/dev.py test-standalone   # Relocated package and incompatible ABI
python3 tools/dev.py generate          # Update C header and Dart bindings
python3 tools/dev.py check-generated   # Compare regenerated files
cargo +1.88.0 test --locked -p podoco -p podoco-ffi
```

Use `python` if that is your Python 3 command. Build tools can resolve their
normal Cargo/pub dependencies; they do not download model weights. Native build
output goes under `target/` or Dart's ignored hook output directory.

## Generated files and dependency locks

Keep `Cargo.lock`, `bindings/dart/pubspec.lock`, `include/podoco.h`, and
`bindings/dart/lib/src/bindings.g.dart` in version control. After changing C
exports, run `generate`, then `check-generated` and `check`. Normal Rust and
Dart application builds use the checked-in bindings and do not regenerate
source files. cbindgen and ffigen versions are pinned in their manifests.

## CI

The repository-root workflow `.github/workflows/podoco.yml` runs only for Podoco
or its workflow changes, plus explicit manual dispatch. It configures desktop
Rust/C/Dart jobs, generated-binding checks, and a minimum-Rust check. The Flutter
application's existing workflow remains separate.
