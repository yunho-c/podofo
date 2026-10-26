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

Use `--copy` for PoDoFo's sandboxed macOS folder picker: granting access to a
bundle directory does not authorize external symlink targets. The native Rust
copy path attempts APFS cloning on macOS. An existing linked bundle can supply
the export root and its `checkpoint/` child for a fresh self-contained copy;
see the [application setup](../../../docs/document-analysis.md).

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

## M2 runtime qualification

The M1 `reference.py`, original manifest, and captures remain unchanged.
`m2_reference.py` adds a separate replay path with deterministic v1 tie handling.
Use the existing Python 3.13 ML environment; no package installation or virtual
environment is required. Start with a new output directory:

```sh
python3.13 tools/pp_doclayout_v3/m2_reference.py prepare \
  --checkpoint /path/to/pinned-checkpoint --output evaluation-output/m2-local
python3.13 tools/pp_doclayout_v3/m2_reference.py append-corpus \
  --checkpoint /path/to/pinned-checkpoint --output evaluation-output/m2-local \
  --research /path/to/docling-layout-heron-coreml \
  --corpus /path/to/IBEM-v1-math-detection-sample
python3.13 tools/pp_doclayout_v3/m2_reference.py rust --output evaluation-output/m2-local
python3.13 tools/pp_doclayout_v3/m2_reference.py compare --output evaluation-output/m2-local
python3.13 tools/pp_doclayout_v3/m2_reference.py classify-ties \
  --checkpoint /path/to/pinned-checkpoint --output evaluation-output/m2-local
```

`prepare` checks the retained M1 captures (override `--capture` when relocated).
The corpus command checks image/archive hashes and gives both implementations
identical Pillow-decoded RGBA, keeping JPEG decoder differences out of the test.
The explicit disk exchange uses ignored Rust qualification tests; it is not a
public tensor-file interface. No weights or corpus images enter ordinary tests.
The full exchange retains roughly a gigabyte of generated inputs and outputs;
keep it under ignored `evaluation-output/`.

Prepare a v1 runtime bundle as described in [layout setup](../../docs/layout.md).
Run `native-python`, `native-rust`, and `native-compare` sequentially with:

```sh
python3.13 tools/pp_doclayout_v3/m2_reference.py native-python \
  --output evaluation-output/m2-local --bundle model-assets/layout-v1 --policy cpu-ne
python3.13 tools/pp_doclayout_v3/m2_reference.py native-rust \
  --output evaluation-output/m2-local --bundle model-assets/layout-v1 --policy cpu-ne
python3.13 tools/pp_doclayout_v3/m2_reference.py native-compare \
  --output evaluation-output/m2-local --policy cpu-ne
```

If Core ML tools is stored in the research checkout's existing package directory,
prefix the Python control command with `PYTHONPATH=/path/to/python-packages`.
Repeat these three commands for `--policy cpu` and `--policy all`. CPU+ANE covers
53 pages; the other policies cover the three synthetic and two known exception
pages. Each implementation predicts twice through one reused model per policy.
The comparison requires raw errors to remain within repeated-control variability
and decoded pairs/order to match, with `1e-6` score/normalized-box tolerance.
Qualification scans mask finiteness without retaining the full masks; its timing
includes that extra work. Use the release CLI for normal pipeline timing.

M2's [tracked evidence](../../docs/internal/m2-validation.md) records the precise
scope and the unchanged experimental-model promotion restrictions.
