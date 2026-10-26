# M6 single-crop recognition qualification

Validated on 2026-10-26, macOS 27.0.1, Apple M4 Pro, on `feat/podoco` after
M5 commit `0bed022`. This is M6's first reviewable part. It qualifies the selected
PP-FormulaNet_plus-L export behind the blocking Rust API; progressive document
recognition and C/Dart formula exposure are separate work.

## Source and artifact contract

The [pinned YAML contract](../../model-manifests/pp-formulanet-plus-l-coreml-v1.yaml)
records checkpoint revision `6cc004a8e91ea3f3819b05317f40b290cbe99c2b`, its model-card
Apache-2.0 declaration, tokenizer/configuration hashes, and exact export/source
inventories. All 11 export payloads, 13 handoff source files, and checkpoint files
matched the research snapshot before preparation. The handoff manifest SHA-256
is `7656d9c6efd2ba3b16c7b75ad5f6069388f5220a0e348c7add04f064aa1890eb`.

The research checkout was read only. Three models were explicitly compiled in
Podoco's ignored `model-assets/pp-formulanet-plus-l-m6` directory. Large payloads
use APFS clones; the original 727 MB checkpoint weights were verified without
copying them. The prepared bundle inventories 33 files and records the local
Core ML compiler hash/Xcode/macOS/architecture. Its manifest SHA-256 is
`f122877f62b7e03e4a80c9e85fdca274f1d49e97ae84c37119119b793c3e1140`.

No cidre change was needed: the existing pinned crate already exposes MLState
creation, scoped state access, and stateful prediction. The runtime validates
every input, output and state name/dtype/shape before accepting a crop. Native
ownership, exception containment and autorelease pools remain on one worker.
The common tensor accessor now supports checked F16 byte copies as well as F32;
strided, wrong-dtype, exact-bit and existing layout regressions pass.

## Exact reference checks

The reference capture uses the existing Python 3.13 environment, with pinned
Transformers 5.8.1, Torch 2.12.0, processor source hashes and local-only loading.
No packages were installed into that Python environment. Rust uses pinned
`half` 2.7.1, `fancy-regex` 0.16.2 and `plsfix` 0.1.8 dependencies.

- **823/823 input tensors are byte-identical:** 811 saved corpus crops and 12
  synthetic cases covering small/square/wide/tall/transparent/uniform inputs and
  a colored margin near the cropping threshold.
- **16,777,216/16,777,216 RGB grayscale values match.** An exhaustive check exposed
  rare differences when two reference fused multiply-add operations were written
  as separate operations. The final implementation uses explicit `f32::mul_add`.
  The grayscale SHA-256, in blue/red/green order, is
  `2f0816f62de428889e63ae82c7ed0fedf2607ddc4b63726de003d1016aa0ccf6`.
- **1,622/1,622 saved token sequences decode identically** to both policy
  references, including raw ByteLevel text and final LaTeX. Eight additional
  processor fixtures cover Chinese wrapping, macros, HTML entities, normalization,
  mojibake, quotes, and terminal escapes. A targeted ftfy-compatible ANSI rule
  corrects the dependency's octal-looking Rust escape literal before control
  removal. This corpus agreement is not proof of every possible Unicode repair.
- **811/811 native CPU outputs and 811/811 native CPU+ANE outputs match their
  corresponding saved Python/Core ML references exactly**, for tokens, raw text,
  normalized LaTeX, and recognized/truncated status. The long 907-token pilot
  exercises 256→2,048 cache promotion. The reference's policy-dependent capped
  expression remains explicitly truncated.

The final native repeat used the corrected grayscale implementation. Native
output hashes and all qualified component source hashes are in the tracked
[compact evidence](../../tests/fixtures/pp_formulanet/m6-single-crop-summary.json).
The executable SHA-256 is
`c4712c6a877a1c0418073cf1153ad67445acc02df6ae57c5d9bbf283423dc222`.
Large raw outputs remain in ignored `evaluation-output/m6-native-full-v2/`;
the final reference capture is `evaluation-output/m6-reference-v2/`.

## Lifecycle and budgets

The native cancellation test interrupts a long expression between decoder steps,
then recognizes the same short expression twice with identical reference tokens
using the existing three loaded graphs. A one-token cap yields `Truncated`;
repeated close succeeds and later requests fail. Portable tests cover original
crop coordinates, RGBA/BGRA, straight/premultiplied/opaque alpha, row padding,
budget rejection, invalid token caps, bounded malformed text, and malformed or
drifting bundle manifests. Output serialization is bounded before publication.

The full native corpus reached **40,108,032 bytes** of accounted decoder
state/promotion scratch and **33,074,240 bytes** of conservative tensor/host
reservation and preprocessing scratch, under the example's 48 MiB and 128 MiB
limits. These observations exclude Core ML weights/workspaces/device buffers,
allocator overhead and text-library static tables. Embedding reads are two
2,048-byte F32 rows per token; there is no full host embedding-table copy.
The native calls were serial by compute policy, on an active AC-powered host.
Timings are diagnostic; this qualification makes no speed, energy or placement
claim and includes no isolated timing comparison.

Full portable development checks, Core ML workspace tests and Clippy with
warnings denied, Rust 1.88 Core ML checks/tests, generated-header checks, and
Python lint/format checks pass. The existing nine-prediction document-job layout
regression also passes after extending tensor access. Existing C/Dart layout
tests establish regression coverage only; this part does not expose formula
recognition through those APIs.

## Reproduction and remaining gates

From `podoco/`, using the explicit local bundle and research checkout:

```sh
python3.13 tools/pp_formulanet/reference.py \
  --research /path/to/docling-layout-heron-coreml \
  --bundle model-assets/pp-formulanet-plus-l-m6 \
  --output evaluation-output/m6-reference-new --all
PODOCO_M6_BUNDLE="$PWD/model-assets/pp-formulanet-plus-l-m6" \
PODOCO_M6_REFERENCE="$PWD/evaluation-output/m6-reference-new" \
  cargo test --locked --release -p podoco --features coreml \
  formula::tests::portable_reference_parity -- --ignored --exact
python3.13 tools/pp_formulanet/check.py \
  --bundle model-assets/pp-formulanet-plus-l-m6 \
  --reference evaluation-output/m6-reference-new \
  --output evaluation-output/m6-native-new
PODOCO_M6_BUNDLE="$PWD/model-assets/pp-formulanet-plus-l-m6" \
PODOCO_M6_REFERENCE="$PWD/evaluation-output/m6-reference-new" \
  cargo test --locked --release -p podoco --features coreml \
  formula::tests::native_cancellation_truncation_and_reuse -- --ignored --exact
```

This establishes deployment parity with the selected export, not mathematical
correctness of every prediction or parity with original FP32 weights. The
selection report's known recognition errors, policy-dependent outputs and
FP16/FP32 differences remain. Detector recall, detector-produced crops, equation
number inclusion, overlap/duplicates, renderer resolution, document updates,
MathCAT, Copy/Listen and human listening/UI acceptance still need their later
milestone checks. Profiles remain experimental. All-compute-unit execution and
other hardware/OS versions are not qualified by this corpus run.
