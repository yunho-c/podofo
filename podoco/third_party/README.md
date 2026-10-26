# Pinned native dependencies

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
