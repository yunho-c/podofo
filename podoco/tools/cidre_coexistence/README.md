# cidre observer coexistence investigation

This development-only experiment compares three candidate patches to cidre
0.29.0. Running it does not modify the Podoco or MLSR source trees or the Cargo
registry. Podoco separately adopts the optional-observer patch in its pinned
dependency; see [Core ML setup](../../docs/coreml.md).
The [findings](../../docs/internal/cidre-coexistence.md) explain the
recommendation and qualification limits.

## Reproduce

On macOS with Xcode, stable Rust, Python 3.11+, `patch`, and the existing cached
Cargo dependencies:

```sh
# From podoco/. Use a new output directory on each run.
python3 tools/cidre_coexistence/run.py \
  --mlsr /path/to/MLSR \
  --output evaluation-output/cidre-observer-local
```

The script discovers the cached cidre 0.29.0 source, or accepts an explicit
`--cidre-source`. It verifies the affected upstream files against
`source-checksums.json`, copies sources to the output directory, applies the
patches there, and builds with Cargo's offline mode. A pre-existing Core ML
MLSR library must be available at `MLSR/target/release/libmlsr_ffi.dylib` for the
mixed patched/unpatched case. The MLSR checkout must contain its affine model
fixture and development-only `coreml_ffi_probe.rs` example. No model downloads,
Python packages, or virtual environments are required.

An optional `--target-dir /path/to/cache` reuses generated Cargo build output.
Do not point it at a production artifact directory. All source copies, dynamic
libraries, model compilation outputs, symbol listings, and logs remain in the
requested output directory (or that explicit build cache). Budget roughly a few
minutes and several hundred MB of generated build output for a fresh run.

## Cases

- Two unmodified libraries reproduce the warning as a positive control.
- `optional`: adds `ns-observer`, included in `full`. Without it, the Rust
  convenience observer API and its Objective-C implementation are absent.
- `split`: moves the factory/class into a separate native archive member,
  retaining the existing Rust API. Normal linking can omit it when unused.
- `namespaced`: accepts `CIDRE_OBJC_CLASS_PREFIX`, validates its spelling, and
  names the Objective-C helper `<prefix>_CidreObserver`. The Rust type/API stays
  the same. Cargo tracks changes to this environment variable.
- Real KVO initial/change callbacks and observer drop are checked when enabled.
- Both loading orders, concurrent Core ML inference, `-ObjC`, debug builds,
  equal-prefix collision controls, invalid prefixes, and disabled-API compile
  failures are covered. The final step runs MLSR's 11 current runtime tests.

The inference probe is taken from the selected MLSR checkout and its hash is
recorded. Each call loads the actual affine Core ML fixture on CPU, checks model
reuse, performs three predictions with alternating output buffers, checks the
expected output and native resource counts, and shuts down. This is runtime
qualification, not a document-model, speech-model, ANE, or performance test.

`qualification.json` records the reproduced result; detailed generated evidence
is kept under the ignored `evaluation-output/` directory. The patches are
alternatives, not a sequence to apply together.

## Upstream provenance and licensing

The patches target the published cidre 0.29.0 crate, source commit
`6f3b3626c98460301c979b4a76f60e23eb3f99f0`. `Cargo.toml` is the crates.io-normalized
manifest; `Cargo.toml.orig` is its upstream source. An upstream proposal should
edit the repository's source manifest, not introduce `Cargo.toml.orig` there.
cidre uses the [MIT license](patches/LICENSE.cidre). The reproduction tooling
and MLSR-derived probe use this repository's Apache-2.0 license.
