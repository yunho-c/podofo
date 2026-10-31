# Rendering quality harness

The harness compares PoDoFo's **production `CustomPdfViewer`** with a direct
PDFium render at the same physical pixel size, page position, and scale. It is
intended to guide changes to bitmap sizing, cache policy, and Flutter image
placement. On macOS, the main viewer uses fractional page transforms and renders
at the settled display scale by default. Other platforms retain their existing
defaults. Both policies can be overridden independently for diagnosis.

The macOS default was promoted after the user confirmed substantially sharper
text and acceptable interactive performance with both flags enabled on
2026-10-31. This is native-app visual acceptance, not a formal performance
benchmark or an automated native-compositor qualification.

After fast-forwarding the rendering branch to `main` at `ce0765f`, captures with
no rendering defines reproduced all 24 low-zoom and all 21 standard-matrix PNGs
from the earlier combined opt-in path byte for byte. Explicitly disabling both
policies reproduced all 21 old-policy control PNGs. Every repeat was stable.
The 22 focused Flutter regressions, 8 Python runner checks, and Flutter analyzer
passed. Local reports are `promoted-default-low-zoom`,
`promoted-default-all-zooms`, and `promoted-opt-out-control` under
`podofo_frontend_one/build/rendering-quality/`; their comparison is recorded in
`default-promotion-evaluation.json` alongside them.

This first version runs in a headless Flutter widget test on macOS. It exercises
the real viewer and its rendering caches, but **does not qualify the native
macOS GPU/compositor**, display color management, or release performance.
PDFium is also PoDoFo's underlying renderer: the reference isolates differences
introduced by the viewer's render requests and presentation. It is not an
independent assessment of PDFium's raster quality. A native capture path and a
second renderer such as PDF.js are future extensions.

## Fractional page transforms

The viewport renderer preserves the exact page scale and fractional translation
inside PDFium's matrix renderer. It rounds only the output tile bounds outwards
on the physical screen grid, then paints that tile at one bitmap pixel per
physical pixel. The visible-page clip prevents the rounded tile from covering
adjacent page backgrounds. The cache checks the tile's placement as well as its
zoom and visible rectangle; stale/cancelled images are disposed. Native work
holds the editable document's backing lease through the PDFium worker operation.

No flags are needed in the macOS app. To compare with the previous rendering
behavior, disable both policies explicitly:

```sh
flutter run -d macos \
  --dart-define=PODOFO_FRACTIONAL_RENDERING=false \
  --dart-define=PODOFO_DISPLAY_SCALE_RENDERING=false
```

The fractional renderer is **on by default on macOS**. It handles PoDoFo's
editable document sessions on macOS. Interactive forms, other document
implementations/platforms,
the magnifier, and the preview cache use the existing path. The debug sidebar
and case metadata identify when the fractional renderer actually supplied the
displayed image. The harness fails if an eligible full-resolution capture
silently falls back while fractional rendering is enabled.

Run paired comparisons from the frontend directory, adding
`--native-frameworks /path/to/PoDoFo.app/Contents/Frameworks` when needed:

```sh
python3 tool/rendering_quality/run.py --no-fractional --no-display-scale \
  --output build/rendering-quality/control
python3 tool/rendering_quality/run.py --output build/rendering-quality/default
```

Initial headless qualification against the baseline at `1ed864e`, before default
promotion (the fractional-only column kept the old preview policy):

| Case group | Standard path | Fractional prototype |
| --- | --- | --- |
| 201 DPI, DPR 1 and 2 | Nonzero RGB difference | Exact match in scored region |
| 209 DPI, DPR 1 and 2, all four offsets | Nonzero RGB difference | Exact match in scored region |
| 209 DPI rotated/cropped fixture pages | Nonzero RGB difference | Exact match in scored region |
| 288 DPI, DPR 1 and 2 | Exact match in scored region | Exact match in scored region |
| 144, 199, 200 DPI preview cases | Existing preview result | Identical to standard path |
| `Assets/documents/relativity.pdf`, page 1, 209 DPI, DPR 2 | RGB MAE 0.6834 | RGB MAE 0 |

All 15 above-threshold synthetic cases matched the direct reference in the
scored area (MAE/RMSE 0 and edge-energy ratio 1); six preview cases retained
their previous measurements. At 209 DPI/DPR 2, the text-region MAE across the
four offsets fell from 3.37–9.20 to zero. Native tests also cover annotation
creation/recolor/undo/redo/removal, settled cache reuse, parent-position changes,
late-image disposal, interactive-form fallback, and cancellation during document
close. Geometry tests cover partial-page edges and fractional placement.

Additional 209-DPI probes at DPR 1.25 matched exactly at all four offsets. At
DPR 3, where the whole page width is visible, offset 0 improved from MAE 1.4247
to 0.000031; the largest remaining RGB-channel difference was one 8-bit level.
The three nonzero offsets in that view are unsupported because the existing
viewer clamps horizontal panning when the page fits. Those rejected probes are
not counted as successful captures.

This establishes headless pixel agreement for these inputs, not general visual
superiority or native compositor/performance qualification. Arbitrary animated
ancestor transforms, continuous scrolling/zooming on native GPUs, interactive
form matrix rendering, broader PDF coverage, and release memory/latency remain
follow-up qualification work. Native rasterization
is synchronous on the existing worker; cancellation discards an obsolete result
rather than interrupting PDFium mid-call.

## Settled display-scale rendering

The display-scale policy, also on by default on macOS, renders the main
viewport at its actual physical display scale at **every zoom**, including at
or below 200 DPI. The existing 200-DPI preview remains available during startup
and interaction. PoDoFo requests a replacement viewport bitmap after 150 ms
without a change to the requested geometry. Identical repaints neither restart
that delay nor cancel an in-flight matching render. Returning to a cached
viewport cancels a pending request for a different viewport.

The default combines it with fractional transforms:

```sh
flutter run -d macos

python3 tool/rendering_quality/run.py --suite low-zoom \
  --output build/rendering-quality/low-zoom-combined
```

Add `--native-frameworks /path/to/PoDoFo.app/Contents/Frameworks` if needed.
Run the same suite with `--no-display-scale --no-fractional` for the preview
control, or `--display-scale --no-fractional` to isolate the cache-policy change.
Omitted switches use the app's defaults; `--fractional` / `--no-fractional` and
`--display-scale` / `--no-display-scale` explicitly override each policy. The
config records omitted overrides as null and results record the effective values.
The debug sidebar identifies the policy and reports `Refining…`
while waiting, then `Inactive` once the preview has been replaced, even below
200 DPI. The flags remain independent for these controlled comparisons.

The 24-case low-zoom suite covers 72, 96, 120, 144, 175, 199, and 200 DPI at
DPR 1; 120, 144, 175, 199, and 200 DPI at DPR 2; four physical offset phases at
144/DPR 1, 199/DPR 1, and 199/DPR 2; and rotated/cropped pages at 144/DPR 1.
72 and 96 DPI at DPR 2 are below this fixture's normal minimum zoom and were
rejected by exploratory captures, so are excluded. Fractional offsets are
tested where the page exceeds the viewport in both dimensions. A custom PDF
omits the three fixture rotation cases and may have different navigation bounds.
The fixed suite cannot be combined with `--dpi`, `--dpr`, or `--offset`.

Headless results with the code based on `9e706ee` (RGB MAE, 8-bit code values,
scored page interior):

| Case | 200-DPI preview | Display scale, ordinary transform | Display scale + fractional transform |
| --- | ---: | ---: | ---: |
| 72 DPI, DPR 1, offset 0 | 1.20311 | 0 | 0 |
| 144 DPI, DPR 1, offset 0 | 1.31291 | 0 | 0 |
| 144 DPI, DPR 1, offset 0.25 | 1.37994 | 7.02362 | 0 |
| 175 DPI, DPR 1, offset 0 | 1.75518 | 4.49282 | 0 |
| 199 DPI, DPR 1, offset 0 | 2.36516 | 5.26355 | 0 |
| 120 DPI, DPR 2, offset 0 | 0.55358 | 0.02793 | 0.02793 |
| 144 DPI, DPR 2, offset 0 | 0.44129 | 0.0000034 | 0.0000034 |
| 199 DPI, DPR 2, offset 0 | 0.75117 | 1.60793 | 0 |

The combined path matches exactly in **22 of 24 cases**, including every
rotated/cropped case. At 144/DPR 1 the preview's thin-line edge-energy ratio is
0.911; at 199/DPR 1 it is 0.837. Both become 1.0 with the combined path. This is
consistent with smoothing introduced by resampling an already antialiased
200-DPI bitmap. Display-scale rendering alone can increase positional error
because the ordinary render API still rounds the page transform.

The two residual cases were isolated by rendering a tight native PDFium tile
with the viewer's geometry and comparing it directly with the captured pixels:
both tiles match PoDoFo exactly. The mismatch is between PDFium's tile render
and its full-viewport reference render, without Flutter resampling. At 120/DPR 2,
0.077% of scored pixels differ by more than two levels, almost entirely in text;
edge energy is 0.99945 of the reference and the maximum channel difference is
73. At 144/DPR 2 the maximum is one level. Integer translation of the bitmap
origin exposes native rasterization sensitivity; the precise PDFium internal
cause has not been established. These are retained as nonzero measurements.

With both policies disabled, the 21-case matrix remained byte-identical to the
committed control, and all 15 above-200-DPI cases still match exactly with both
flags. Regression tests
exercise preview availability, settling after repeated zoom changes, immunity
to unrelated repaints, cancellation when returning to a cached viewport, and
annotation creation/recolor/undo/redo/removal below 200 DPI.

On `Assets/documents/relativity.pdf`, page 1 at DPR 2, the combined path also
matches exactly at 144 and 199 DPI. Preview MAE is 0.33315 and 0.30388,
respectively; the matched references are byte-identical between runs.

Local comparison artifacts are in `podofo_frontend_one/build/rendering-quality/`:
`low-zoom-control`, `low-zoom-display-integer`, `low-zoom-display-fractional`,
`low-zoom-default-regression`, and `low-zoom-combined-regression`. Each run has
its own report and provenance receipt. `low-zoom-evaluation.json` records the
three-way comparison, and `low-zoom-text-comparison.png` shows a matched 144-DPI
text crop enlarged with nearest-neighbor sampling for inspection. Artifacts are
local and ignored by Git. `low-zoom-relativity-control-final` and
`low-zoom-relativity-combined-final` contain the real-document comparisons.
`inspect-low-zoom-tiles.py` and `low-zoom-tile-diagnostic.json` preserve the
standalone native replay of the residual cases. Widening its bitmap without
changing the local page origin leaves the pixels unchanged, while restoring the
full-viewport origin reproduces the reference exactly.

This policy adds viewport rasters below the old threshold while retaining the
preview cache. Its 150-ms delay and allocation estimates are not a release
latency/memory benchmark. Automated native GPU capture, measured scrolling
performance, and broader document/platform qualification remain follow-up work
after the user's native-app acceptance. Form fallback and the
fractional renderer's platform limits described above still apply.

## Run

Use the repository's pinned Flutter SDK and configured frontend dependencies
(`.fvm/flutter_sdk`, `flutter pub get`, and the existing MLSR SDK setup). The
runner uses the installed Dart VM directly to preserve macOS `DYLD_*` variables.
Python 3.11 or later is required; the runner has no Python package dependencies.

An existing macOS PoDoFo build supplies `PDFium.framework/pdfium` and
`ObjectBox.framework/ObjectBox`. By default the runner looks in the frontend's
`build/macos/Build/Products/Release/PoDoFo.app/Contents/Frameworks`. A build in
another worktree can be selected explicitly; it is read without modification.

From `podofo_frontend_one`:

```sh
# Complete synthetic matrix (21 cases).
python3 tool/rendering_quality/run.py

# Focused 209-DPI capture using frameworks from an existing build.
python3 tool/rendering_quality/run.py \
  --dpi 209 --dpr 2 --offset 0 \
  --native-frameworks /path/to/PoDoFo.app/Contents/Frameworks

# A real document and a specific page (one-based).
python3 tool/rendering_quality/run.py \
  --pdf /path/to/document.pdf --page 3 \
  --dpi 209 --dpr 2 --offset 0 \
  --output build/rendering-quality/my-document-209
```

`--dpi`, `--dpr`, and `--offset` may each be repeated. Offset is a translation in
**physical pixels in both axes, relative to the centered viewport**; it is not
an absolute pixel-grid phase. The actual fractional page origin is recorded.
The logical viewport is 800 × 600; physical dimensions are rounded after applying
DPR. DPR is limited to 4. `--pdfium` (or `PDFIUM_PATH`) can select the native
binary explicitly. `--flutter-sdk` selects the SDK and `--timeout` bounds the
entire capture job (default 600 seconds).

Each run creates a new directory under `build/rendering-quality/` unless
`--output` is supplied. Existing output is always refused. Open `report.html`
directly in a browser; keep its case directories alongside it. The report needs
no server or external assets. Captured document content and local source paths
are included, so review the artifacts before sharing them.

## What is compared

The generated PDF embeds the repository's Urbanist font and contains 6–20 pt
text, 0.15–2 pt strokes, curves, grayscale patches, and asymmetric color marks.
Four pages cover 0°, 90°, 180°, and 270° rotation; the last two also have crop
boxes. Generated dates and trailer IDs are normalized without changing byte
offsets. The input PDF, native binaries, dependency manifests, SDK revision,
application/vendor Dart sources, and harness sources have recorded SHA-256
hashes. Git HEAD and dirty status are recorded as additional context, not used
as a substitute for source hashes.

The default matrix is 144, 199, 200, 201, 209, and 288 DPI at DPR 1 and 2. At 209
DPI it also tests offsets of 0.25, 0.5, and 0.75 physical pixels. Three focused
209-DPI/DPR-2 cases exercise the rotated and cropped pages. Custom PDF runs use
only the requested page, with no synthetic rotation cases added.

For each case the job opens a fresh document session, mounts the production
viewer with light appearance and inactive narration/search, and sets the
viewport transform. It waits for the actual `renderingStatus` and a painted
frame: with the macOS defaults, the completed viewport render at every zoom;
with `--no-display-scale`, the preview bitmap at or below 200 DPI and the
completed partial render above 200 DPI. It does not change image filtering.
A clamped viewport is rejected instead of silently comparing at a different zoom.

The reference uses `FPDF_RenderPageBitmapWithMatrix` through the same document
worker and PDFium binary. Its final-sized opaque-white RGBA image incorporates
the measured fractional page position directly; neither image is aligned or
resampled after capture. PDFium applies the page's intrinsic crop and rotation.
Render flags include annotations and the limited image cache, matching the
viewer's default render. An independent integer-size PDFium API comparison on
all four fixture pages checks the reference geometry before scoring any cases.
A known color mark also checks absolute placement and channel order.

`RepaintBoundary.toImage(pixelRatio: dpr)` captures the viewer. A second painted
frame must be pixel-identical within the scored page interior. This checks
settled-frame stability; it does not establish reproducibility across machines,
PDFium versions, or GPU backends. The fixture is embedded-font deterministic;
local PDFs with unembedded fonts may depend on font substitution on this host.

## Artifacts and interpretation

Each case stores lossless `reference.png`, `podofo.png`, and `difference.png`.
`results.json` contains transforms, page dimensions/rotation, target and preview
scale, actual render mode, input hash, metrics, repeat checks, timing, and bitmap
size estimates. `receipt.json` records provenance and completion status;
`config.json` and `capture.log` preserve the invocation and test output.

The HTML report provides synchronized image scrolling, native-pixel and enlarged
views, reference overlay, blink (`B`), and matched region crops. Blink respects
the browser's reduced-motion preference. Its difference image is the maximum
absolute RGB channel difference multiplied by 8 and saturated at 255, shown in
red. It is deliberately unmasked, so page edges, shadows, and UI may appear.

Metrics use a page-interior mask inset by 2 physical pixels and exclude the
rightmost 24 logical viewport pixels where the production scrollbar may draw.
The synthetic unrotated page additionally has text, thin-line, and grayscale
patch regions, clipped to the visible scored area. Each metric records its exact
pixel rectangle. Local PDFs receive the page-interior measurement only.

* RGB MAE and RMSE use 8-bit sRGB code values.
* Changed-pixel fraction counts pixels with any RGB channel difference > 2.
* Edge-energy ratio compares summed absolute horizontal/vertical Rec.709-luma
  gradients (candidate/reference); it is null for a flat reference.
* Ink coverage is the fraction of pixels with code-value luma below 127.5.

These are **diagnostics, not perceptual quality pass/fail gates**. A subpixel
shift can produce large errors without blur; a low edge ratio can indicate
smoothing but is not a standalone quality judgment. Review matching crops and
overlay/blink views. Use the same document, input hash, PDFium binary, viewport,
and DPR when comparing runs. The report's completion badge means the harness
checks succeeded, not that the viewer has acceptable visual quality.

`settle_wall_ms` measures the requested viewport update through the ready painted
frame, after initial viewer startup, with test-runner polling overhead. Memory
fields estimate bitmap sizes, not peak allocations or process memory. Neither
field is a release performance benchmark.

## Validation and failure behavior

Every capture run checks identity, Gaussian blur, a one-pixel shift, and an
undersized-then-upscaled raster. The altered controls must be detected, and blur
must reduce edge energy. Geometry controls must agree with PDFium's ordinary
integer-size renderer. Repeated viewer captures must agree exactly in the mask.

Invalid pages, failed renders, clamped viewports, unstable frames, and timeouts
are reported as failures with a nonzero exit. AcroForm/XFA documents are
explicitly unsupported because this reference path does not paint interactive
form appearances. Missing prerequisites and invalid arguments fail before
creating an output directory. Once a capture starts, failure still produces a
report and receipt; partial case results remain visible. A timed-out capture's
process group is terminated, including Flutter's tester child.

Fast runner checks and metric unit tests:

```sh
python3 -m unittest discover -s tool/rendering_quality -p 'test_*.py' -v
flutter test --no-pub test/rendering_quality_test.dart
flutter analyze --no-pub
```

The actual viewer/native integration is validated by `run.py`, not by the metric
unit tests. Related repository regressions are `debug_rendering_status_test`,
`pdf_selection_paint_test`, `highlight_refresh_test`,
`fractional_rendering_test`, `fractional_rendering_geometry_test`, and
`display_scale_rendering_test`; use the existing macOS
native-test setup for those.
