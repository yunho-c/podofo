# Model manifests

No model has been selected or bundled yet. Future model contracts use YAML and
record immutable upstream revisions, artifact paths/sizes/hashes, tensor and
pre/postprocessing contracts, runtime/shape requirements, provenance, and
model-specific licenses.

Keep downloaded weights outside Git (for example in ignored `model-assets/`).
Preparation must verify local artifacts and make downloads explicit. Normal
library builds must not fetch model weights. The SDK's Apache-2.0 license does
not imply that a model's weights use the same license.

Define the first concrete manifest with the first selected model, rather than
introducing an untested universal schema now.
