# Internal PDF link hover previews

After the existing 350 ms hover delay, supported internal PDF links display a
contextual destination image beneath their page label. On macOS Apple Silicon,
PDF text and the bundled Podoco layout model can replace that image once with
a complete, identified target: a bibliography entry, figure/table with its
caption, numbered equation, or section heading and first paragraph. Existing
layout evidence is reused; uncached target pages are analyzed on demand.

Ambiguous identity, incomplete boundaries or unavailable analysis retain the
contextual preview. Unlinked citation text and figure references are outside
this feature's scope. External links keep their text tooltip. Hover does not
navigate, modify the document, record history or suspend narration.

Implementation and automated/corpus qualification are recorded in the
[M5 report](target_aware_link_preview_m5.md). Native-window acceptance remains
open because Computer Use denies PoDoFo access; M5 is not complete.

## Contextual destination handling

| Destination | Preview |
| --- | --- |
| XYZ | Context around the supplied position; destination zoom is ignored. |
| FitH / FitBH | Context around the supplied vertical coordinate. |
| FitV / FitBV | Context around the supplied horizontal coordinate. |
| FitR | The supplied rectangle, padded by 12 points and clipped to the page. |
| Fit / FitB | An aspect-preserving view of the whole visible page. |
| Missing coordinates in a supported command | A page preview when both axes are absent; the page center supplies a missing axis. |
| Unknown, malformed, unsafe or out-of-range destination; render failure | Existing page label only. |

Position previews cover up to 480 × 320 PDF points, centered on the target and
shifted inside the visible page at its edges. This preserves surrounding context
at every rotation. This first image is a location preview and can show only part
of a large target; it remains visible while semantic preparation runs.

## Target resolution

The resolver combines the source annotation's selected text, bounded adjacent
text, native destination and target-page layout. A nearby layout box alone is
insufficient. It matches numbered and author-year references, named figure/table
captions, equation numbers and numeric/Roman/appendix section labels. Figure
panels require evidence in the parent figure; accepted previews retain the
whole parent. References preserve continuation lines, URLs and page backlinks.
Section previews include the heading and complete opening paragraph.

A target may use a safe union or at most four crop parts on at most two adjacent
pages. Only a demonstrated continuation requests the next page. Known unrelated
regions prevent a semantic crop. Explicit FitR destinations provide their own
area without semantic model inference. Unsupported platforms, missing assets,
textless pages, malformed destinations and uncertain grouping retain the
contextual image or page-label fallback.

Remaining fallbacks include multi-panel source fragments, missing panel/group
evidence, references whose identity year appears only on the following page,
ambiguous last-entry boundaries, and some equation-interleaved section openings.
There is no whole-document preprocessing, OCR, formula recognition or Docling
runtime dependency on hover. Manual Analyze retains priority over automatic
preview work. See the [implementation plan](target_aware_link_preview_plan.md).

pdfrx 2.6.5 / pdfrx_engine 0.6.1 return raw PDF destination coordinates, whereas
text and annotation rectangles use the page bounding-box origin. The renderer
reads PDFium's unrotated bounding box through `useNativeDocumentHandle`, subtracts
its origin and applies the page rotation before selecting the raster region.
It does not use the viewer's navigation matrix. The pinned engine backport
preserves absent XYZ coordinates separately from zero, normalizes reversed link
annotation rectangles and closes annotation handles. Unknown axes stay unknown
for semantic matching; rendering may use a page center for contextual framing.
The pdfrx/PDFium dependency versions remain locked.

## Ownership and limits

- Contextual images fit within 360 × 240 logical pixels; semantic images fit an
  adaptive envelope up to 480 × 360. Device pixel ratio is capped at 2, limiting
  a semantic output to 960 × 720 pixels (2,764,800 BGRA bytes). Multipart rendering
  is sequential with at most 5,529,600 accounted temporary BGRA bytes. Virtual
  full-page dimensions are capped at 32,768 per axis.
- A viewer owns a decoded-image LRU limited to eight entries and 6 MiB. Keys
  include source annotation, destination, session/revision, evidence/resolver
  identity, density and render envelope. No decoded preview images are placed in
  Flutter's global `ImageCache` or on disk. Text is bounded to eight pages/4 MiB
  and 200,000 UTF-16 units per page. The separate persisted-layout cache is
  bounded to 16 MiB, with 4 MiB per page and strict provenance checks.
- Each worker keeps at most one active render and the newest pending request.
  New requests cancel the previous token and replace pending work. Cancellation
  is best effort inside PDFium; generation/session/revision checks discard late
  results even if native rendering cannot stop immediately.
- PDF extraction and rendering use short session read locks and owned snapshots.
  Disk reads and model inference run outside those locks, so close/edit can
  detach waiting consumers. Session/revision checks suppress stale results.
  Every temporary `PdfImage` is disposed in `finally`. The cache owns its
  `ui.Image` handles; the overlay owns a clone. Eviction, cancellation and widget
  disposal release their respective handles.
- Pointer movement/exit/down, keyboard input, scrolling, viewport changes, tab
  changes and document revision changes invalidate the hover. The overlay is
  clamped to its actual overlay bounds and ignores pointer input.

These limits bound preview rasters, decoded cache storage and outstanding work.
They do not impose a process-wide memory limit on PDFium's interpretation of
arbitrarily complex source PDFs.

Click navigation and Back continue through the existing code paths. The model
is loaded lazily from verified offline assets; cached-layout identity reads do
not open inference and cannot substitute for full model-payload verification.

## Regression coverage

- `link_preview_worker_test.dart`: coordinate geometry, all rotations, absent and
  invalid parameters, pixel/virtual-size limits, LRU disposal, cloned ownership,
  value-based keys, revision/session isolation, replacement of pending requests,
  failures and late results after cancellation/close/disposal.
- `link_preview_native_test.dart`: a generated five-page PDF with real GoTo links,
  nonzero MediaBox/CropBox offsets, rotations of 0/90/180/270 degrees, Fit and FitR,
  cross-page targets and invalid page numbers. Pixel assertions locate a known
  colored target in each native crop; no user PDFs or network links are opened.
- `pdf_link_hover_preview_test.dart`: small-overlay edge placement, text fallback
  and pointer pass-through.
- `reader_hover_preview_test.dart`: the real keyed reader area, 350 ms debounce,
  unchanged matrix/page/history, external labels, click/Back, rapid movement,
  stale completions, tab switching, scrolling and closing.

## Validation on 2026-10-28

This historical section describes the original isolated hover harness. The
subsequent locked macOS integration, full tests and signed builds supersede its
dependency/build limitations: see the [M0 baseline](target_aware_link_preview_m0.md)
and [current M5 report](target_aware_link_preview_m5.md). Native-window acceptance
is still pending.

**23 focused tests passed:** 13 new cases plus 10 existing navigation, document
lease and link/cache cases. Analysis of the eight changed Dart files reported no
issues. Formatting and `git diff --check` passed. Native crop captures were
inspected. The repository's pubspec and lockfile are unchanged.

This is **isolated-harness evidence**, not a full application build. The Linux
runner used Flutter 3.47.5 / Dart 3.13.4, the committed hosted dependency versions,
PDFium chromium_7811 and ObjectBox 5.3.2. `PDFIUM_PATH` pointed at the bundled
library and `LD_LIBRARY_PATH` at ObjectBox. All preview and reader sources under
test were copied unchanged from this branch.

The pinned MLSR commit `0ca5d81bbcad0fa8a6274ebe3a7e44200bdc4da6` could not be
fetched from its repository (Git and GitHub API both rejected that SHA). The
available MLSR revision `14ff251` lacks `DurationPlan`, `DurationPlanningJob`,
`Tts.planDuration` and `Speech.timeline`, so substituting it does not compile the
unchanged application. For the harness only, the default narration provider's
MLSR adapter import/factory was replaced with a fail-fast factory; the tests
explicitly supplied the existing fake narrator. Available MLSR bindings/native
assets satisfied hook preparation but were not used for playback. This harness
substitution is not included in the branch or patch.

Full locked application validation, desktop builds and native GUI acceptance
remain to be run with the intended MLSR checkout available. No remote CI was
triggered and no branch, PR, release or deployment was published.

With the normal project dependencies and native libraries prepared, run from
`podofo_frontend_one`:

```sh
flutter analyze --no-pub
flutter test --no-pub \
  test/link_preview_worker_test.dart \
  test/link_preview_native_test.dart \
  test/pdf_link_hover_preview_test.dart \
  test/reader_hover_preview_test.dart \
  test/reader_navigation_test.dart \
  test/pdf_document_lease_test.dart \
  test/cache_and_links_test.dart
```

Before merging, inspect linked citations and figures in representative academic
PDFs, including edge-of-window hovers, high-DPI displays, dark appearance, rapid
tab changes and closing during rendering. Confirm normal click/Back behavior and
that hovering unlinked reference text does not show a preview.
