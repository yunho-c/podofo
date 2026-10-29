# Rendering quality harness

The harness compares PoDoFo's **production `CustomPdfViewer`** with a direct
PDFium render at the same physical pixel size, page position, and scale. It is
intended to guide changes to bitmap sizing, cache policy, and Flutter image
placement. It does not change the viewer's rendering policy.

This first version runs in a headless Flutter widget test on macOS. It exercises
the real viewer and its rendering caches, but **does not qualify the native
macOS GPU/compositor**, display color management, or release performance.
PDFium is also PoDoFo's underlying renderer: the reference isolates differences
introduced by the viewer's render requests and presentation. It is not an
independent assessment of PDFium's raster quality. A native capture path and a
second renderer such as PDF.js are future extensions.

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
frame: the normal preview bitmap at or below 200 DPI, and the completed partial
render above 200 DPI. It does not turn off the reduced-DPI cache or change image
filtering. A clamped viewport is rejected instead of silently comparing at a
different zoom.

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
`pdf_selection_paint_test`, and `highlight_refresh_test`; use the existing macOS
native-test setup for those.
