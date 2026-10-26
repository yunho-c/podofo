# M6 progressive document recognition

Validated on 2026-10-26, macOS 27.0.1, Apple M4 Pro. This follows single-crop
commit `5196426`. The combined Rust/C/Dart implementation is complete for the
experimental PP-DocLayoutV3 + PP-FormulaNet_plus-L profile. It does not promote
either model to a production quality claim.

## Runtime and binding evidence

The same 50 original-resolution IBEM pages used in M2 run through one Rust
document job with CPU+ANE permission and a 2,048-token cap. The source renders
one page at a time; recognition reads each covering crop directly from the
original page allocation. No context padding, equation-number merging, extra
NMS, or duplicate suppression is introduced.

- **50/50 pages finish**, with **531 recognized outcomes** (436 inline, 95
  displayed), zero failed/truncated outcomes, and **632 acknowledged updates**.
  Layout, individual formulas, final pages and document completion are delivered
  progressively. The first formula arrives before document completion.
- **531/531 detector-crop LaTeX/status results match** the pinned Python/Core ML
  runner. This is separate from M6a's 811 ground-truth-crop token comparisons.
  All selected source image hashes and the reference runner/processor sources
  are verified. The reference uses precisely the detector's floor/ceil crop.
- **632/632 Dart update payloads and sequences equal Rust**, including both model
  manifests, final page snapshots and summary. Run IDs are intentionally unique.
  The consumer uses a relocated Dart package and an explicit Core ML dylib.
- **Six Dart tests pass**: token-cap validation, copied/leased multipage parity,
  cancellation after the first acknowledged formula, decoder reuse after that
  interruption plus a later source failure, explicit one-token truncation, and
  combined-budget rejection. Native handles return to zero after disposal;
  controlled native allocations release exactly once after all model reads.
- The portable C test rejects malformed paths/caps/configuration before loading
  models. Dart rejects an ABI-1 library and an older ABI-2 artifact without the
  formula extension before resolving missing symbols. The ABI stays 2 with an
  additive feature bit; clients must probe it before formula configuration.

The original layout-only native Dart suite and CLI remain a regression gate.
Workspace tests/Clippy with warnings denied, Rust 1.88 Core ML checks, generated
header/binding checks, and portable development checks pass. Raw evidence is
ignored under `evaluation-output/m6-documents-v1`, `m6-dart-v1`, and
`m6-layout-regression`; [compact evidence](../../tests/fixtures/pp_formulanet/m6-document-summary.json)
records the qualified source/artifact hashes and complete job counters.

The full Rust job peaks at 16,777,216 reserved input bytes, 2,113,536 serialized
result/producer-reservation bytes and two pending updates. Final live counts are
zero. Tensor/cache admission is 128 MiB/48 MiB for this run. The combined adapter
reserves 32 MiB for the inactive session and requires a 96 MiB tensor floor;
formula cache promotion still needs 40,108,032 bytes. Core ML model weights,
workspaces/device buffers and caller-retained results are outside these counters.
These are bounded SDK reservations, not measured process RSS. Recorded wall
times include opening and an active host; no isolated speed or ANE-placement
claim follows from these parity runs. Native inference runs were serial.

## Quality and crop behavior

The dataset is a deterministic 50-document convenience sample with 811 annotated
equations (715 embedded, 96 isolated). Greedy one-to-one matching uses descending
IoU with a 0.5 threshold and stable tie breaks. Recognition scores use the
research tokenizer/edit-distance metric, preserving structure and choosing the
best of the dataset's three LaTeX references. This is text agreement, not a proof
of mathematical equivalence.

| Observation | Result |
| --- | --- |
| Matched detections / ground truth | 486 / 811 (59.93% recall) |
| Matched detections / predictions | 486 / 531 (91.53% precision) |
| Embedded / isolated annotations matched | 393 / 715; 93 / 96 |
| Exact recognition among matched detector crops | 238 / 486 |
| Mean token similarity on matched detector crops | 87.455% |
| Same recognizer on matched ground-truth crops | 232 exact; 87.050% mean similarity |
| Exact matched results / all ground truth | 238 / 811 (29.35%) |

The ground-truth baseline has two pixels of context; detector crops have none.
The comparison measures the actual crop-policy difference and does not attribute
it to a runtime improvement. **Detection recall, especially embedded math,
remains a substantial quality limitation.** The 325 unmatched annotations and 45
unmatched detections are retained in raw evidence; matched predictions and their
reference scores are saved for review.

There are 16 overlapping formula pairs, including overlapping inline math; none
are silently deduplicated. Two other region pairs have same-category IoU ≥ 0.95:
the known duplicate heading on `0009027_page01`, and a text pair on
`0012145_page01`. One formula on `0006108_page05` overlaps more than half of a
separately detected equation-number box. Visual inspection of its original crop
shows the clipped `(12)` at its right edge; recognition includes `(12)` in LaTeX.
The adapter preserves that output instead of guessing whether to strip it.
These crop observations and the existing M2 FP16/FP32 differences remain visible
promotion gates for M9. `Recognized` means EOS with nonempty decoded text, not
that the equation is correct.

## Reproduction

From `podoco/`, use explicit immutable local assets. New output roots must not
already exist for the native and Dart stages:

```sh
python3.13 tools/pp_formulanet/documents.py native \
  --layout model-assets/pp-doclayout-v3-m2 \
  --formula model-assets/pp-formulanet-plus-l-m6 \
  --fixtures evaluation-output/m2-portable-v1 \
  --research /path/to/docling-layout-heron-coreml \
  --output evaluation-output/m6-documents-new
# With the handoff's existing coremltools package directory on PYTHONPATH:
python3.13 tools/pp_formulanet/documents.py reference \
  --layout model-assets/pp-doclayout-v3-m2 \
  --formula model-assets/pp-formulanet-plus-l-m6 \
  --fixtures evaluation-output/m2-portable-v1 \
  --research /path/to/docling-layout-heron-coreml \
  --output evaluation-output/m6-documents-new
python3.13 tools/pp_formulanet/document_quality.py \
  --documents evaluation-output/m6-documents-new \
  --research /path/to/docling-layout-heron-coreml
python3.13 tools/check_formula_jobs.py \
  --layout model-assets/pp-doclayout-v3-m2 \
  --formula model-assets/pp-formulanet-plus-l-m6 \
  --documents evaluation-output/m6-documents-new \
  --output evaluation-output/m6-dart-new --dart /path/to/pinned/dart
```

Standalone crop recognition is currently the blocking Rust `FormulaSession`.
Document recognition uses the existing analyzer queue across Rust/C/Dart. Math
conversion, renderer-owned native leases, application formula caching/actions,
concurrent MLSR use, and human listening/UI acceptance remain M7–M9 work.
