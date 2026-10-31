# Pinned native dependencies

## MathCAT host integration

`mathcat/` contains the published MathCAT 0.7.7 Rust source/manifests/build script,
README and [MIT license](mathcat/LICENSE). The exact published crate, whose VCS
metadata declares a dirty source tree, is the authority; the Git commit alone is
not a reproducible replacement. [mathcat-source.json](mathcat-source.json) records
its archive checksum, selected file inventory and the
[host patch](mathcat-podoco-host.patch). Upstream tests/site images are omitted;
rules are separately provisioned, hash-verified offline assets.

The opt-in `podoco-host` feature disables installation of MathCAT's process-global
panic hook and discovery of host user preferences, and enables upstream
`no-unsafe`. Its build script watches embedded rules only with `include-zip`,
which Podoco does not enable. Other feature configurations preserve upstream
behavior. Podoco uses a direct path dependency, without patching other MathCAT
consumers in the application graph or modifying the registry cache.

Run `python3 tools/verify_mathcat.py` to check every source and patch hash. Start
updates from the verified published archive, reapply and review the host patch,
then requalify the rules, process-global effects, worker isolation and conversion
corpus. Retain upstream formatting: use `cargo fmt -p podoco -p podoco-ffi -p
podoco-codegen`, since `cargo fmt --all` traverses local path dependencies.

The optional registry dependencies `pulldown-latex` 0.8.0 (MIT) and
`roxmltree` 0.21.1 (MIT/Apache-2.0) retain their published licenses and are pinned
in Cargo.toml/Cargo.lock. See [math conversion](../docs/math.md) for the strict
profile, rule asset/license preparation and qualification boundaries.

## cidre observer exclusion

`cidre/` contains the complete published cidre 0.29.0 crate from upstream commit
`6f3b3626c98460301c979b4a76f60e23eb3f99f0`, with the
[observer feature patch](../tools/cidre_coexistence/patches/cidre-0.29.0-optional.patch)
applied. The upstream [MIT license](cidre/LICENSE.txt) is included separately
because the published archive omitted it. All other files retain upstream
formatting. `cidre-source.json` records the published archive checksum, patch
checksum, and SHA-256 of every file in this patched copy.

The patch adds `ns-observer = ["ns"]` to opt into the native `CidreObserver` class
and Rust convenience API; `full` includes it to preserve default behavior.
Podoco disables cidre's defaults and requests only `ml`, `macos_15_0`, and
`ios_18_0`. It does not request `ns-observer`. No registry cache modification or
build-time patch application is needed.

```sh
# From podoco/. This also runs in tools/dev.py check on every platform.
python3 tools/verify_cidre.py
```

For an update, start from a checksum-verified published crate, apply the reviewed
patch, restore its upstream license, regenerate the file inventory, and rerun
the [Core ML coexistence check](../docs/coreml.md). Updating a hash alone is not
evidence that a new upstream version still excludes the observer. Keep this
temporary copy until an upstream solution can replace it. No upstream proposal
has been submitted yet.

## Ported interpolation and reduction algorithms

`crates/podoco/src/pipelines/layout/preprocess.rs` and the order-vote reduction in
`pipelines/layout/mod.rs` adapt the native uint8 bicubic and Float32 summation
algorithms from PyTorch commit `7661cd9c6b841b62b7f411aa52ec51f05457263b`:
[`UpSampleKernel.cpp`](https://github.com/pytorch/pytorch/blob/7661cd9c6b841b62b7f411aa52ec51f05457263b/aten/src/ATen/native/cpu/UpSampleKernel.cpp),
[`UpSample.h`](https://github.com/pytorch/pytorch/blob/7661cd9c6b841b62b7f411aa52ec51f05457263b/aten/src/ATen/native/UpSample.h), and
[`SumKernel.cpp`](https://github.com/pytorch/pytorch/blob/7661cd9c6b841b62b7f411aa52ec51f05457263b/aten/src/ATen/native/cpu/SumKernel.cpp).
The upstream [license and notices](pytorch-LICENSE) are retained. There is no
PyTorch dependency in the Rust library.

The Core ML ownership, exception, autorelease-pool, and checked tensor-access
patterns are adapted from the Apache-2.0 MLSR runtime at
`14ff251eb7e9011801945233cf91ef8b444cd734`, with attribution in the Rust modules.
The SDK has no MLSR runtime dependency. PP-DocLayoutV3 decoding follows the
Apache-2.0 PaddlePaddle/Hugging Face processor pinned by the model manifest.

Formula preprocessing also adapts PyTorch's antialiased uint8 linear/cubic
resampling from that same commit, with the license above. Margin cropping,
thumbnail/padding, normalization, and formula text rules follow Transformers
5.8.1's Apache-2.0 PPFormulaNet processors (Copyright 2026 The PaddlePaddle Team
and The HuggingFace Inc. team), whose exact files are hashed in the
[formula contract](../model-manifests/pp-formulanet-plus-l-coreml-v1.yaml).
The ByteLevel decoder implements the pinned tokenizer's reversible byte
alphabet; the SDK does not load a BPE encoder. Registry dependencies `half`
(MIT/Apache-2.0), `fancy-regex` (MIT), and `plsfix` (MIT) are version pinned in
Cargo.toml/Cargo.lock. Their published packages retain their own license files.
