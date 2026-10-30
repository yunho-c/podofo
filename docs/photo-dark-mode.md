# Experimental photo-preserving PDF dark mode

Review prototype based on `main` commit
`3e143209e91321bbae06607ce563a63c30febee5`. Nothing is pushed or merged by this
change. The existing `invert.frag` and dependency lockfile are unchanged.

## Enable and expected behavior

In dark mode, right-click the theme button, enable **Invert PDF Colors**, then
**Preserve photos (experimental)**. The new preference defaults to **off**,
including for existing installations. Inversion strength retains its existing
meaning; notably zero strength in the original shader is not a no-op.

The main reader preserves likely photographs while text, vector figures and
rejected raster figures use the original HSL lightness transform. Thumbnail
inversion remains unchanged. Until analysis completes, and on analysis or
selective-shader loading failure, the existing whole-view inversion is used.
Photos may visibly change from inverted to natural after this initial delay.
Turning the option off immediately restores the existing rendering path.

This is a conservative heuristic, not semantic image recognition. It intentionally
misses some photographs and can mistake sufficiently textured scientific images
or screenshots containing photographs for photographs. There is no accuracy
claim based on a single source photograph and no per-region user override yet.

## Developer diagnostics

In the developer sidebar, expand **Dark Mode** and enable **Show
photo-preservation diagnostics**. This temporary toggle defaults off and also
works in light mode or with preservation disabled. It shares the viewer's
visible-page analysis/cache; enabling diagnostics adds no second viewer or page render.

- Green outlines indicate image regions actually passed to the preservation
  shader. Accepted images beyond the 16-region limit are gray and labeled
  `visible-region-limit`.
- Orange outlines indicate rejected raster images. Labels include the page,
  zero-based PDF object path, and the first failed gate. A path such as `60/2`
  means page object 60, then child 2 inside that Form.
- Gray outlines indicate skipped/inactive images. Accepted photos show
  `inversion-off`, `preservation-off`, or `selective-shader-unavailable` when
  preservation is inactive. Forms are traversed and their raster children appear
  individually; there is no longer a `form-not-inspected` placeholder.

Expand an object's sidebar entry to see its reason and, when pixel classification
was reached, all six measured statistics alongside their thresholds. Multiple
thresholds may fail even though the reason reports only the first. Pending pages,
page-level failures and analysis limits are reported explicitly; a page rejected
before object enumeration cannot supply outlines. Offscreen objects on a visible
page may appear in the sidebar without a visible outline.

Outlines and labels are painted after the color filter and ignore pointer input.
Selection, links and navigation continue through the overlay. The diagnostic
toggle retains the existing viewer and viewport. The sidebar follows the active
document session, and document revisions invalidate cached results. Neither this
toggle nor the extra metadata changes photo-classification thresholds.

Diagnostics validation on 2026-10-29: 26 focused tests passed in the macOS
Flutter 3.47.5 test runner with Impeller and the existing Debug app's PDFium
framework. Coverage included native rejection/Form/budget metadata, the sidebar,
pointer passthrough, retained selection/viewports, reader/navigation regressions,
document leases, page layouts and the shader pixel probe. Static analysis and
format checks passed. Captures are in `build/photo-dark-mode/`; this is test-runner
evidence, not a new Release application build or interactive acceptance.

## Content inspection and classification

`photo_analysis.dart` reads the **live session document**, not a separately opened
source file. `PdfSession.readLocked` holds a document lease and serializes against
edits, save and close. `useNativeDocumentHandle` in the pinned pdfrx engine pauses
its PDFium worker throughout the awaited callback. Raw calls execute in a short
auxiliary isolate while that worker remains suspended. All native pages and
bitmaps are closed in `finally`; only detached geometry/decisions return. The
prototype never initializes or destroys the shared PDFium runtime.

Inspection flattens page objects and nested Form XObjects into paint order using
`FPDFPage_GetObject` and `FPDFFormObj_GetObject`. It composes parent matrices,
inherits Form transparency and clipping, and inspects the raster leaves. Native
bounds already include each object's own matrix; only its ancestors are applied
again. Form containers do not themselves count as overlapping paint.

Once an image passes the opacity check, earlier paint is treated as covered.
Later text, images and ambiguous drawing paths still block preservation. For
bounded, straight-edged filled paths, contour edges plus the PDF fill rule can
prove that an image lies in an unpainted hole. This handles figure frames exported
as filled polygons. When a frame meets the photo edge, a one-point inset must be
proved clear before preserving that smaller rectangle. Curves, strokes, and
filled regions inside the rectangle stay conservative. Native annotations remain
part of the viewer composite.

An image must pass **every** gate:

| Gate | Prototype criterion |
| --- | --- |
| Geometry | Axis-aligned image or exact quarter-turn; arbitrary skew/rotation rejected |
| Visibility | No image/Form transparency state; visible rendered pixels have full alpha; simple rectangular clips supported |
| Isolation | No later paint in the retained rectangle; bounded polygon holes can prove clear interiors |
| Page size | Visible width and height at least 24 PDF units; less than 65% of the visible page area |
| Pixels | Source at least 64 × 64; source and local rendered bitmap each at most 4 million pixels |
| Tonal entropy | At least 4.5 bits over 64 luminance bins |
| Color diversity | At least 90 occupied 4-bit RGB palette cells |
| Flat neighbors | At most 45% of horizontal/vertical luminance differences are ≤2 |
| Sharp edges | At most 18% of neighbor luminance differences are ≥64 |
| Extreme tones | At most 30% of samples have luminance <12 or >243 |
| Distributed texture | At least 10 of 16 tiles each have 100 neighbor differences in [6,48] |

Pixel statistics use a fixed 64 × 64 center sample of the visible crop, mapped
back to source pixels through the inverse composed matrix, without interpolation
or a learned model. Low-color plots, white-background plots, screenshots and
smooth gradients in the fixture are rejected. Grayscale photos are also rejected
by the palette gate; scans/full-page photos, small images, photos with overprinted
PDF labels, complex clips, transparencies and complex image transforms stay
inverted. These are deliberate false negatives, not features claimed to work.

Each geometric clip subpath must describe one axis-aligned rectangle after
ancestor transforms; multiple such clips are intersected with the page and image
bounds. Compound paths, holes, curves, unknown clips and zero-path referenced
clips are rejected. Because the public clip API omits text clipping, any clipping
text render mode found on a page conservatively rejects its image candidates.
The empty, unreferenced PDFium clip wrapper has `CountPaths == -1`.

`FPDFImageObj_GetBitmap` ignores intrinsic image masks, and
`FPDFPageObj_HasTransparency` alone does not detect an image's `/SMask`. Admission
therefore also uses `FPDFImageObj_GetRenderedBitmap`, checking **every** pixel's
alpha within the retained region before sampling raw source colors. Source and
rendered sizes are checked before allocation, both count toward the page pixel
budget, and both bitmaps are immediately destroyed. No live object matrices,
clips or PDF bytes are changed. The relevant contracts are in
[PDFium's image API](https://pdfium.googlesource.com/pdfium/+/main/public/fpdf_edit.h)
and [implementation](https://github.com/chromium/pdfium/blob/main/fpdfsdk/fpdf_editimg.cpp).

This alpha check is at PDFium's local object-render resolution, which can differ
from both source resolution and eventual viewer zoom. It rejects the soft,
explicit and color-key masks in the fixtures; it is not a structural guarantee
that a PDF resource has no mask, nor full-resolution mask-aware compositing.
Subpixel mask details and arbitrary translucent composites remain later-stage
work. Source/target size bounds also cannot bound every internal decoder or mask
allocation; the deadline remains soft.

## Coordinates and compositing

Ancestor-transformed object bounds and supported clips are intersected with
`FPDF_GetPageBoundingBox`; the crop
origin is subtracted to match pdfrx's unrotated `PdfRect` convention. The same
`PdfRect.toRectInDocument` conversion used by pdfrx applies page rotation and
layout scaling. The actual viewer layout supplies each page's spread offset.
Finally, the current visible document rectangle maps these coordinates to the
filter input's normalized coordinates. No screen-space, window-origin or device
pixel ratio assumptions are used. Geometry tests compare against PDFium's
`FPDF_PageToDevice` for rotations 0/90/180/270 and nonzero crop origins.

`PhotoPreservingFilter` always keeps one `PdfViewer`, its listener/gesture tree,
and one `ImageFiltered` mounted. Its own shader belongs to the viewer; it does not
mutate the shared default/thumbnail shader. A separate `invert_photos.frag` copies
the original HSL calculation and bypasses it inside up to 16 visible photo
rectangles. No second PDF render or bitmap overlay is introduced.

The bypass preserves the **already composited pixels**, including any annotation,
selection, search or narration overlay within the rectangle. Those overlay
pixels consequently retain their uninverted color there, while pixels outside
use the existing transform. This is region-level bypass, not separate treatment
of image and overlay layers. Native embedded text/vector overlays disqualify the
photo as described above. Excess visible photo regions stay inverted.

## Work and memory bounds

Only visible pages are admitted, with a 150 ms delay after the visible page set
changes and between jobs. Analysis is serial; scrolling replaces queued pages.
A 64-page LRU caches both positive and negative results. Zooming/panning a cached
page recalculates rectangles only. Revisions invalidate the cache; stale results
from an in-flight job are discarded. Disposal releases queued work, while the
active job retains its lease until it finishes. Eviction or reopening a tab can
cause analysis again; the cache is not persisted across tabs/restarts.

Admission limits: 2,000 total objects across Forms, 16 nested Form levels,
24 raster placements, 8 million source-plus-rendered pixels per page,
and an 80 ms soft deadline checked between candidates. Native page loading or
an individual image decode cannot be interrupted by that deadline. A costly
cold decode can still delay pdfrx's renderer while the worker is paused, even
though it does not block Dart's UI isolate. Source bitmaps are freed immediately;
only detached decisions/regions are retained. Diagnostic metadata is capped at
128 raster objects per page, with omitted counts reported; image classification
still admits at most 24 images. Geometric clips admit at most eight rectangles
per object; filled-path overlap proofs admit at most 256 segments per path. Extreme
zoom-out admits only the first 64 visible pages to avoid cache thrashing.

## Form inspection qualification on 2026-10-30

The macOS Flutter 3.47.5 runner uses the existing Debug app's PDFium framework.
All 17 focused tests, the separate local-paper shader qualification, and static
analysis passed. The combined shader checks compared 5,642,700 pixel samples.
The committed `forms.pdf` adds 26 deterministic pages covering nested quarter-turn
and reflected transforms, repeated Forms, image/ancestor/BBox clips, paint order,
text clipping, intrinsic masks, transparency groups, depth/image/allocation
limits, fractional placement and filled frame holes. Tests verify expected
crop-relative bounds and object paths, plus unchanged PDF pixels and text after
analysis. The sidebar test exercises sibling object paths without duplicate keys.
The actual Impeller probe also covers ten of these pages at two scales and three
inversion strengths, including the cropped and framed photo edges.

Local-paper qualification (papers are not committed) preserved **3 crops on
GVC-RT page 8** and **5 crops on ResGVC page 16**. Actual Impeller output matches
natural pixels within accepted regions and the original dark-mode transform
outside them. Rendered captures were inspected for caption/table/label legibility.
The large photos with inset labels/boxes still fail overlap admission; some small
crops fail the unchanged palette, entropy or flatness thresholds. This is partial
coverage, not full figure or document acceptance. Dense GenRecon pages still face
the unchanged 24-image limit. No new Release build or interactive-window
acceptance is claimed by these test-runner checks.

Reports and natural/original/selective PNGs are under
`build/photo-dark-mode/paper-qualification/` and `build/photo-dark-mode/impeller-test/`.
To repeat with other local papers, set `PHOTO_PAPER_CASES` to a JSON file containing
`[{"path":"/absolute/paper.pdf","pages":[8]}]`, then run
`tool/qualify_photo_papers_test.dart` with Impeller and the same native libraries.
The opt-in probe requires at least one accepted photo on each requested page.

## Verification performed on 2026-10-28

Linux x64, Flutter **3.47.5**, Dart **3.13.4**, pdfrx **2.6.5**,
pdfrx_engine **0.6.1**, pdfium_dart **0.3.1**. Final native checks used the PDFium
`chromium/7811` binary obtained by the pinned package's build hook, SHA-256
`d106072a29b3689a5d6739948f98a97fe3ec82f5a1c309dc44e86f6c549fb44e`.

- 17 focused tests passed: six new classifier/preference/cache tests, three new
  real-PDF tests, and eight existing lease/layout/highlight-selection regressions.
- One Impeller-enabled viewer test passed: the production wrapper, navigation,
  retained word selection, mode toggles, two-page layout, a rotated page,
  nonzero outer padding, and a translucent paint overlay. Captured pixels inside
  photo masks match the uninverted viewer; outside pixels match the original
  filter. Toggling preserves the viewer instance and navigation matrix.
- One explicit Impeller shader probe passed **1,024,821 sampled pixel comparisons**
  over six pages, two render scales, and strengths 0, 0.6 and 1. It includes a
  native highlight drawn over a photograph and all quarter-turn rotations.
  The probe requires `ImageFilter.isShaderFilterSupported` and executes
  `ImageFilter.shader` with offscreen readback; it is not a shader mock.
- One diagnostic benchmark passed; static analysis of the changed Dart code,
  focused tests and qualification tools passed. Fixture regeneration/hash and
  formatting were checked separately.

| Diagnostic | Measured result |
| --- | --- |
| 24 uncached page analyses, including synchronization/isolate | First 46.334 ms; median 2.433 ms; range 0.633–46.334 ms |
| PDFium page rendering at 600 × 800, 12 pages | Median 4.398 ms; range 2.361–25.333 ms |
| 10,000 cached lookups + rectangle projections | 15.866 ms total, about 1.59 μs each; no extra native analyses |
| Offscreen filter + image readback, 36 samples per mode | Original median 0.621 ms; selective median 0.514 ms |

The offscreen sequence always ran the original filter first and included cold
initialization, mixed image sizes and JIT behavior. Its negative median difference
is **not a performance improvement claim**. There is one filter pass in both
modes; the selective pass adds up to 16 rectangle tests per pixel and skips HSL
work inside a photo. Interactive frame-time/FPS, target-device GPU overhead,
Release memory/RSS and long scrolling sessions remain unmeasured.

### Qualification limits

The actual **Release application was not built or run**. This Linux host cannot
qualify the macOS Release/Metal path, and preparation also failed because the
repository pins MLSR commit `0ca5d81bbcad0fa8a6274ebe3a7e44200bdc4da6`, which both
Git and the GitHub API reported unavailable. The pinned SDK and lockfile were
not altered. Focused validation used a separate source copy/harness removing
only the three MLSR dependencies and their native hook. This does not qualify
MLSR, the full reader, desktop packaging, or the complete existing test suite.

The headless Impeller evidence is stronger than ordinary widget tests but is not
Release desktop acceptance. Metal, Windows, GLES/backend orientation, device DPI
changes, rapid tab switching during slow decoding, and full native context-menu/
link/annotation-edit flows still need target-platform review. No new backend
support is claimed beyond the original shader's requirements.

Testing also exposed a pdfrx select-all paint failure (`PdfPageTextRange` on an
empty-fragment page) when selecting across the fixture's image-only pages. The
stack is in pdfrx's selection paint path, and the failure occurred with selective
mode off. This prototype does not change that path; the passing selection check
uses word selection. Cross-page select-all over image-only pages is unqualified.

## Reproduce and review

With the normal app prepared, run from `podofo_frontend_one`, supplying the same
PDFium binary as the application (see `tool/test_macos.py` on macOS):

```sh
flutter test --no-pub --concurrency=1 \
  test/photo_dark_mode_test.dart test/photo_dark_mode_native_test.dart \
  test/photo_forms_native_test.dart \
  test/pdf_document_lease_test.dart test/pdf_page_layout_test.dart \
  test/highlight_selection_test.dart
flutter test --no-pub --enable-impeller \
  test/photo_filter_widget_test.dart test/photo_diagnostics_sidebar_test.dart
flutter test --no-pub --enable-impeller tool/qualify_photo_shader_test.dart
flutter test --no-pub tool/benchmark_photo_analysis_test.dart
```

If MLSR remains unavailable, `python3 tool/prepare_photo_test_harness.py
/absolute/path/to/new-harness` prepares the limited harness (requires PyYAML).
Run `flutter pub get --enforce-lockfile` in it. For the qualified Linux test path,
set `PDFIUM_PATH="$PWD/build/native_assets/linux/libpdfium.so"` before the tests;
the package hook creates that binary during test preparation. Keep `CI=true` on
headless hosts to avoid Flutter's cloud-metadata environment detection. This is
a focused verification workaround, not an application distribution configuration.

The deterministic inputs and their attribution are in
`test/fixtures/photo_dark_mode/`. Regenerate with
`python3 tool/generate_photo_fixture.py` and
`python3 tool/generate_photo_forms_fixture.py` using Pillow 12.3.0. Test/probe outputs are
under `build/photo-dark-mode/` and must not be treated as Release evidence.

`tool/photo_release_probe.dart` reuses the same pixel checks in a real Release
app and refuses an existing evidence directory. On a prepared macOS host:

```sh
flutter run -d macos --release -t tool/photo_release_probe.dart \
  --dart-define=PHOTO_FIXTURE=/accessible/absolute/path/mixed.pdf \
  --dart-define=PHOTO_OUTPUT=/accessible/absolute/path/new-evidence
```

Use paths accessible to the sandboxed app, such as its own container. Inspect
`report.json` and the PNGs, then rebuild the ordinary app. Finally review actual
paper PDFs: toggle inversion/strength, pan and zoom, switch single/two-page
layouts, select/copy text, create/remove highlights, follow internal links/Back,
and switch/close tabs while analysis is pending. Review gray photographs,
heatmaps, microscopy, screenshots and scanned papers for false positives and
false negatives before expanding this experimental classifier.
