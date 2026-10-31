# Model manifests

PP-DocLayoutV3 is selected for layout detection; formula-recognition selection is
ongoing. [The experimental Core ML manifest](pp-doclayout-v3-coreml.yaml) is
implemented with offline Rust verification and local preparation. No production
model bundle has been qualified in Podoco yet.
The [implementation plan](../../docs/podoco-implementation.md) defines the handoff
and qualification gates. Model contracts use YAML and
record immutable upstream revisions, artifact paths/sizes/hashes, tensor and
pre/postprocessing contracts, runtime/shape requirements, provenance, and
model-specific licenses.

Keep downloaded weights outside Git (for example in ignored `model-assets/`).
Preparation must verify local artifacts and make downloads explicit. Normal
library builds must not fetch model weights. The SDK's Apache-2.0 license does
not imply that a model's weights use the same license.

This concrete schema supports the pinned PP-DocLayoutV3 profile; it is not a
universal tensor runtime. See [preparation and reference tooling](../tools/pp_doclayout_v3/README.md)
for local-only commands, integrity boundaries, and source attribution.
