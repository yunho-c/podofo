# Internal PDF link hover previews

After a 300 ms hover delay, supported internal PDF links prepare a
destination preview. On macOS Apple Silicon, PDF text and the bundled Podoco
layout model can identify a complete target: a bibliography entry, figure/table
with its caption, numbered equation, or section heading and first paragraph.
Existing layout evidence is reused; uncached target pages are analyzed on demand.

Once the contextual raster is ready, the reader allows up to 150 ms for the
smart preview before revealing the card. A smart result arriving in that window
appears directly at its final size, without flashing the page-label placeholder
or larger contextual image. If preparation finishes without a smart result, the
fallback appears immediately. If preparation is still running at the deadline,
the contextual preview appears and can be replaced once by the smart result.
This bounds the extra presentation delay, but slow cold analysis can still
produce a visible replacement. Leaving the link before a card appears cancels
the pending reveal.

The selected card fades in over 100 ms. Movement within the source link keeps
the same card and anchor, including while smart preparation is running. Once the
card is visible, a 250 ms exit delay lets the pointer cross the gap onto it;
hovering either the link or the card keeps the preview open. Leaving both starts
the exit delay and then a 100 ms fade. Dismissal cancels preparation and retains
the displayed image only until that fade completes. Modifier keys alone do not
dismiss the card. Escape and other commands, clicks in the reader, scrolling,
document changes and disposal still remove it immediately. Reduced-motion
settings disable both fades.

Internal preview cards receive pointer input within their own bounds. Clicking
a card does not navigate or select the PDF underneath; a separate popup action
is not implemented yet. Clicking the source link retains normal navigation.
External-link text tooltips remain inert.

Smart previews use the target's size at the current reader zoom, including the
page-layout scale. A floor of one logical pixel per PDF point helps text at low
zoom; the complete target shrinks uniformly when it reaches the pane limits.
The whole card is capped at 60% of the PDF pane's width and height and at
960 × 720 logical pixels, with an 8-pixel edge margin. Placement uses the PDF
pane rather than the surrounding window or sidebars. Zoom changes dismiss the
current card; the next hover captures the new scale. Raster cache keys include
those captured page scales while text and layout evidence remain reusable.

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
of a large target; after the reveal grace period, it remains visible while
semantic preparation runs.

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

- Contextual raster outputs fit within 360 × 240 logical pixels. Smart cards
  use the pane-relative envelope above, including label and padding. Device
  pixel ratio is capped at 2, with a hard semantic raster limit of 1920 × 1440
  pixels (11,059,200 BGRA bytes). Multipart rendering is sequential with at most
  22,118,400 accounted temporary BGRA bytes. Virtual
  full-page dimensions are capped at 32,768 per axis.
- A viewer owns a decoded-image LRU limited to eight entries and 24 MiB. Keys
  include source annotation, destination, session/revision, evidence/resolver
  identity, density, render envelope and captured page scales. No decoded preview images are placed in
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
- Movement within the active source link and hovering its card preserve the
  request. Leaving both expires after the exit delay; real commands, scrolling,
  viewport changes, tab changes and document revision changes invalidate it.
  Only the card captures pointer input, leaving the rest of the reader available.

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
- `pdf_link_hover_preview_test.dart`: small-overlay edge placement, text fallback,
  inert-tooltip pass-through and input confined to interactive cards.
- `reader_hover_preview_test.dart`: the real keyed reader area, 300 ms debounce,
  first-frame smart-preview selection, bounded slow-analysis fallback, cancelled
  reveals, unchanged matrix/page/history, external labels, click/Back, rapid
  movement, stale completions, tab switching, scrolling and closing; fade timing,
  image ownership during dismissal, reduced motion, same-link movement, modifier
  keys, link-to-card travel, and clicks isolated from the underlying PDF.

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
