# Internal PDF link hover previews

After the existing 350 ms hover delay, supported internal PDF links display a
rendered destination preview beneath their page label. This includes linked
citations and figures. Unlinked citation text and figure references are outside
this feature's scope. External links keep their text tooltip.

## Destination handling

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
at every rotation. This is a location preview, not semantic figure extraction;
a figure can extend beyond that region.

The proposed [target aware preview plan](target_aware_link_preview_plan.md)
describes using Podoco layout and PDF text to identify complete targets. That
behavior is not part of the current implementation.

pdfrx 2.6.5 / pdfrx_engine 0.6.1 return raw PDF destination coordinates, whereas
text and annotation rectangles use the page bounding-box origin. The renderer
reads PDFium's unrotated bounding box through `useNativeDocumentHandle`, subtracts
its origin and applies the page rotation before selecting the raster region.
It does not use the viewer's navigation matrix. Destination values inherit the
pinned engine's parsing: PDFium's `GetView` can represent a PDF null parameter as
zero. Fit/FitB remain the explicit page-only forms; this change does not patch
the dependency's destination parser.

## Ownership and limits

- Preview content fits within 360 × 240 logical pixels. Device pixel ratio is
  rounded to half steps and capped at 2, so output never exceeds 720 × 480 pixels
  (1,382,400 bytes of BGRA pixels per raster). Virtual full-page dimensions are
  capped at 32,768 per axis, and PDFium's limited image-cache flag is enabled.
- A viewer owns a decoded-image LRU limited to eight entries and 6 MiB. Keys
  include destination values and density; the cache is scoped to a session and
  revision. Switching sessions, changing revision, or disposing the viewer clears
  it. No entries are placed in Flutter's global `ImageCache` or on disk.
- Each worker keeps at most one active render and the newest pending request.
  New requests cancel the previous token and replace pending work. Cancellation
  is best effort inside PDFium; generation/session/revision checks discard late
  results even if native rendering cannot stop immediately.
- Rendering and decoding hold the session's read lock and document lease, so
  edits, reloads and close cannot dispose the PDF underneath an active job.
  Every temporary `PdfImage` is disposed in `finally`. The cache owns its
  `ui.Image` handles; the overlay owns a clone. Eviction, cancellation and widget
  disposal release their respective handles.
- Pointer movement/exit/down, keyboard input, scrolling, viewport changes, tab
  changes and document revision changes invalidate the hover. The overlay is
  clamped to its actual overlay bounds and ignores pointer input.

These limits bound preview rasters, decoded cache storage and outstanding work.
They do not impose a process-wide memory limit on PDFium's interpretation of
arbitrarily complex source PDFs.

Hover does not navigate, modify the document, record history, or suspend narration.
Click navigation and Back continue through the existing code paths. No dependency
versions, storage schema, narration implementation or native platform files change.

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
