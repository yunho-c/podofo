# PP-DocLayoutV3 offline tooling

The checked-in YAML is an experimental integration baseline. No command here
implements Podoco inference or chooses a formula recognizer. Ordinary Rust/C/Dart
checks need no model weights or Python ML packages.

Run commands below from `podoco/`. Use the existing Python 3.13 environment for
reference work; do not create a virtual environment or install packages globally.

## Local preparation

The public Rust verifier also powers the example preparation command:

```sh
cargo run --locked -p podoco --example model_bundle -- prepare \
  model-manifests/pp-doclayout-v3-coreml.yaml \
  /path/to/ppdoclayoutv3-prototype \
  /path/to/pinned-checkpoint \
  model-assets/pp-doclayout-v3-m1
cargo run --locked -p podoco --example model_bundle -- verify \
  model-assets/pp-doclayout-v3-m1
```

The export root must contain `optimized-mixed.mlpackage` and
`optimized-mixed.mlmodelc`. The checkpoint root supplies the four metadata files
listed in the manifest. No download or compilation is performed. Preparation
links individual files by default to avoid duplicating weights; add `--copy`
for an independently relocatable copy, including hosts without symlink support.
Sources and link targets must stay immutable. Existing destinations are rejected.

The tool verifies staging first, reserves a new destination, moves artifacts,
and publishes the manifest last. It removes its own newly created incomplete
destination/staging on handled errors. A process kill may leave staging or an
incomplete directory; verification rejects missing manifests/payloads, and no
automatic cleanup deletes an ambiguous existing directory.

Manifests reject duplicate YAML keys, unsupported profiles, traversal/absolute
paths, and duplicate inventories. Artifact directories reject nested directory
symlinks/cycles, missing/unlisted payloads, and changed bytes. File symlink target
bytes are hashed. Regular `.DS_Store` metadata is excluded from inventory.
Trusted manifests can supply payload inventories; checksum verification is not
publisher authentication or native model parsing.

## Original fixtures and reference capture

Three original project pages cover columns/tables, equation-like content, and
odd-sized straight-alpha/rotated raster geometry. Their PNGs and generator are
redistributable project fixtures. They are not a layout-accuracy corpus. The
font is rasterized using Pillow's bundled default; no font binary is redistributed.

```sh
python3 tools/pp_doclayout_v3/reference.py check-fixtures
# Explicit regeneration only, using pinned Pillow 10.4.0:
python3.13 tools/pp_doclayout_v3/generate.py
```

Capture uses the pinned local eager FP32 checkpoint and validates its raw hashes,
package versions, and model/processor source hashes. Hub access is disabled.
It checks the box/order subset against the actual upstream postprocessor.
Large input tensors, small raw outputs, and selected mask logits/thresholds stay
under the ignored output directory. Each fresh capture needs a new destination.

```sh
python3.13 tools/pp_doclayout_v3/reference.py capture \
  --checkpoint /path/to/pinned-checkpoint \
  --output evaluation-output/m1-reference-v1
python3.13 tools/pp_doclayout_v3/reference.py replay \
  --checkpoint /path/to/pinned-checkpoint \
  --output evaluation-output/m1-reference-v1
```

Replay recomputes preprocessing and decoding from saved raw outputs, checking
exact arrays/JSON and selected-mask thresholds. It does not rerun the model or
measure performance. Ordinary CI runs only the standard-library fixture checker.
Optional capture/replay needs the pinned existing ML environment and local assets.
The tracked summary and decoded JSON are compact review evidence; capture arrays
are not checked into Git. Model-only and processor-only execution remain outside
normal builds.

The reference environment is recorded in the YAML (Torch 2.12.0, Torchvision
0.27.0, Transformers 5.8.1, NumPy 2.3.5, Pillow 10.4.0); the upstream full
postprocessor also uses the existing OpenCV installation. Coremltools is not
required by this eager capture/replay command.

## Existing 50-page evidence

`tests/fixtures/pp_doclayout_v3/ibem50.json` indexes the existing external IBEM
images and compressed captures by hash, preserving recorded conversion agreement
and decoded reference data. The original document images stay outside this repo.
Its legacy comparison is score-sorted, while the new processor reference is
reading-order-sorted; the two formats are explicitly distinguished.

```sh
python3.13 tools/pp_doclayout_v3/reference.py index-legacy \
  --research-root /path/to/docling-layout-heron-coreml \
  --corpus /path/to/IBEM-v1-math-detection-sample \
  --output tests/fixtures/pp_doclayout_v3/ibem50.json
```

This inventories existing evidence only. It does not rerun the 50-page study or
alter the sibling research checkout. The extra detections on
`0005219_page07.jpg` and `0009027_page01.jpg` remain explicit.

## Attribution

The box/order decode operations follow the Apache-2.0 Transformers 5.8.1
`PPDocLayoutV3ImageProcessor`, copyright 2026 PaddlePaddle and Hugging Face.
The implementation/source hashes and upstream model-card license declaration are
preserved in the manifest. Model weights retain their upstream license; the SDK
license does not relicense external documents or datasets.
