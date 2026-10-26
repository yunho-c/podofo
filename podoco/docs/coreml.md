# Core ML dependency and coexistence

The optional `coreml` feature selects a pinned, patched cidre 0.29.0 dependency
on macOS/iOS. It establishes the native dependency and build policy; Podoco's
public APIs still expose identity only. A document-model runtime and Dart
inference API have not been implemented. macOS 15 and iOS 18 are the selected
deployment floors; only macOS arm64 has been exercised locally.

```sh
# From podoco/, with Xcode and its command-line tools selected.
MACOSX_DEPLOYMENT_TARGET=15.0 cargo build --locked -p podoco-ffi --features coreml
python3 tools/check_coreml.py
# Also co-load an existing MLSR Core ML library in both orders:
python3 tools/check_coreml.py --mlsr-library /path/to/libmlsr_ffi.dylib
```

The check compiles the checked-in affine fixture with Xcode and performs real
CPU-only predictions through a development-only dynamic-library example. It
checks both output arrays, reuses the model for three predictions per call,
and runs concurrent independent calls in fresh processes. Release, debug, and
`-ObjC` builds must omit the observer class and coexist with a library where the
observer is enabled. The optional MLSR check calls its identity API alongside
Podoco's inference probe. Logs, symbols, and results are saved under
`target/coreml-check/` by default. No model download or Python packages are used.

The `coreml_probe` example is not a public C ABI. Its output is not a document
analysis, ANE performance, minimum-OS, or iOS qualification. The default Dart
hook continues to build the identity-only library without `coreml`.

## Rust consumers

Podoco uses a path dependency on the [vendored source](../third_party/README.md),
so a path or Git dependency on Podoco retains the observer patch automatically:

```toml
[dependencies]
podoco = { path = "/path/to/podofo/podoco/crates/podoco", features = ["coreml"] }
```

If one Rust application also depends on MLSR or another registry cidre user,
add this override to the **application's workspace root** to unify cidre:

```toml
[patch.crates-io]
cidre = { path = "/path/to/podofo/podoco/third_party/cidre" }
```

Cargo only honors patches from the root workspace; a dependency's root patch
does not propagate. See [Cargo's patch reference](https://doc.rust-lang.org/cargo/reference/overriding-dependencies.html#the-patch-section).
Without that override, path and registry cidre are distinct packages, with
separate native bridges. The override applies to compatible cidre versions;
inspect `cargo tree -d` when adding another consumer.

## Native library policy

Separately built Podoco and MLSR dynamic libraries can each use Core ML. For the
currently selected features, Podoco's build omits `CidreObserver`, allowing the
existing MLSR build to remain unchanged. Apple supplies the shared Core ML
framework; Rust and cidre wrapper code can still be duplicated between libraries.

Cargo features are additive: another dependency enabling cidre's `full`, default,
or `ns-observer` features in Podoco's own native build can restore the observer.
Keep these disabled for this packaging arrangement and retain the same-process
check when the application starts bundling Podoco. If both libraries later need
the convenience observer, use distinct per-library class names; the
[investigation](internal/cidre-coexistence.md) includes a tested candidate patch.
Namespacing is not part of the adopted dependency.
