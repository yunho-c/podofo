# Queued explicit-crop API qualification

Date: 2026-10-26. Host: M4 Pro, macOS 27.0.1. SDK Dart 3.13.5;
application Flutter 3.47.5 / Dart 3.13.4. This follow-up completes the queued
crop API promised by the design. It does not promote the experimental models.

## Implemented boundary

Rust `Analyzer::recognize_formula`, C `podoco_formula_job_start`, and Dart
`Analyzer.recognizeFormula` submit a lazy, identified crop through the same FIFO
as document jobs. They reuse loaded models and do not run layout detection.
Whole-page and crop-only rasters preserve owning page/revision, region ID,
canonical bounds, affine mapping and explicit inline/displayed context.

`FormulaJob` owns cancellation, coalesced progress and authoritative completion.
The result uses the existing recognized/failed/truncated `FormulaOutcome`.
Source/geometry errors remain owned failures; native failure closes the lane.
The input reservation survives cancellation until the loader, native readers
and foreign image-release acknowledgements drain. A separate C release barrier
holds the shared lane until Dart disposes the image; it is not a layout event.

ABI remains 2. Feature bit 32 gates the new entry point before symbol resolution.
Existing document envelopes gain an additive kind field. The binding shares its
source/control/release pumps while keeping crop and document outcomes typed.

## Reproduction

From `podoco/`, choose a fresh output directory and keep the model inputs immutable:

```sh
CARGO_INCREMENTAL=0 python3.13 tools/check_formula_crops.py \
  --layout model-assets/pp-doclayout-v3-m2-sandbox \
  --formula model-assets/pp-formulanet-plus-l-m6 \
  --reference evaluation-output/m6-reference-v2 \
  --documents evaluation-output/m6-documents-v1 \
  --legacy-native /path/to/pre-extension/libpodoco_ffi.dylib \
  --output evaluation-output/explicit-crops-v3
```

The runner snapshots the release Core ML/math library before testing, relocates
the Dart package with an enforced lockfile, checks exact saved LaTeX and handle
counts, and records source/reference/native hashes. Its optional legacy check
uses a real earlier formula-enabled ABI-2 artifact. No downloads or package
installation are required. The [checked-in receipt](../../tests/fixtures/explicit-crop-summary.json)
links the ignored full results.

## Checks and limits

- The portable workspace check passes: 38 core unit tests (two explicit corpus
  tests ignored), 19 contract/image/bundle integration tests, seven FFI tests,
  and one doctest. Dart has ten portable tests with 22 opt-in cases skipped;
  relocated-package and older-ABI rejection checks also pass.
- Rust 1.88 checks all targets with Core ML/math. Clippy passes all targets with
  both optional features and warnings denied. Generated C/Dart checks, Dart
  analysis/formatting, C smoke, Python lint/syntax and whitespace checks pass.
- Eight deterministic crop scheduler tests cover identity/no detection,
  document/crop FIFO capacity, queued cancellation without rendering, active
  cancellation/lease lifetime, geometry/output bounds, source failures,
  token truncation, native panic, lane shutdown, drain ordering and callback
  wait rejection. These tests validate lifecycle, not model quality.

All six crop, six document and one legacy-compatibility cases passed without
skips. Sixteen saved real crops were each recognized through both copied and
leased inputs: **32 exact LaTeX matches** against the M6 CPU+ANE deployed Python
reference. Crop-only rasters had nonzero translation into a larger owning page,
and tests alternated explicit inline/displayed context. The release counter was
16 for the 16 leases; the final native handle count was zero. A cancelled late
renderer also proved its release callback ran before the next queued loader.
Source failure, incomplete crop coverage, queue overflow, queued cancellation,
token truncation and analyzer disposal were exercised against real native models.

Document regression tests compare two-page copied/leased output to the retained
Rust reference and cover progressive cancellation, later-page source failure,
lower token caps and rejected model budgets. This follow-up does not repeat the
full 50-page/811-crop M6 quality study. The earlier formula-enabled ABI-2 artifact
rejects explicit crops with `unsupported_capability` before resolving the absent
symbol, without rendering or leaking handles.

The qualified native snapshot SHA-256 is
`5c725c391955bcd4fbdc4ec05d2bda9f9662886a89816f60ae0441c0d0c16ddf`;
the prior library is
`a795084659122d5c2ae2b62389c8b0aae1a1e06d38b840b6b90d9278a662e0bb`.
Earlier runner v2 passed its tests but rejected the receipt because application
preparation replaced the shared Cargo artifact during the run. The runner now
tests its own immutable snapshot; v3 passed the source/artifact stability checks.
The initial FFI test also expected the wrong code for a version mismatch; it was
corrected to require `unsupported_schema`. Failed logs remain retained.

## Application regression

After preparing the updated SDK, `tool/qualify_podoco_equations.py --skip-build`
ran with the self-contained layout bundle, existing formula/rules assets and M8
PDF. The app was left available for human testing; this follow-up did not rebuild
or replace its bundle. Flutter analysis passed, as did one real native concurrent
analysis/muted-MLSR test and 33 UI/controller/cache tests, without skips.
Eight formulas completed; exact `A_{m-1}` Copy and MathCAT text
`cap a sub m minus 1 end sub` were preserved. Analysis remained active at the
first observed equation audio progression. Both native handle counts returned
to zero. The signed test artifact hash is
`0e9e4d6ba09d0d7b67a507dca4a19935fa54b33aa4c32f472bc1a5481312d3cc`.

Raw evidence is in
`podofo_frontend_one/build/podoco-qualification/crop-api-regression-v1`; the
compact SDK receipt includes its hashes and observations. These active-host
correctness checks do not establish throughput, ANE placement, minimum-OS
support, model promotion or human listening acceptance.

## Sandbox asset correction

Human testing exposed an asset-packaging mistake: the initial layout development
bundle contained 12 file symlinks into the research checkout/cache. A macOS
directory grant does not authorize those external targets. A second reported
missing-manifest path pointed at the shared `model-assets` parent instead of an
individual bundle. Neither error established a failure in the crop API.

The existing verified `model_bundle prepare --copy` command materialized
`model-assets/pp-doclayout-v3-m2-sandbox`. Its 13 files contain no symlinks and
match the original hashes, including manifest
`3799c3091c7087111111a38847a35e7db882176d3466d3a54159bb517212abef`.
On this APFS host, the standard Rust copy path attempts native clones. Formula
and math folders were already self-contained. The original research assets and
linked bundle remain unchanged. [Application instructions](../../../docs/document-analysis.md)
now distinguish the bundle folder from its parent and require self-contained
payloads for sandbox use. User confirmation after this correction remains a
separate acceptance item.
