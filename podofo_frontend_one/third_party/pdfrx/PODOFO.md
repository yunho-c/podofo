# PoDoFo pdfrx staging backports

This is the runtime source of published **pdfrx 2.6.5**, under its original MIT
license (see `LICENSE`). It includes `lib`, `assets`, and `bin`; upstream examples,
tests, tools, and the promotional screenshot are omitted. The package archive's
SHA-256 was `52e78d84a706e5d63d2502689fe8e800d823bc780ac4341b2d3683a4d726505a`.

The app uses this relative path so a fresh checkout gets the fix without edits
to the pub cache or a dependency on a sibling repository. `pdfrx_engine` and
PDFium remain the locked published dependencies. Web assets are retained so
this source copy does not remove a platform supported by the original package.

Changes from the published package:

- `pubspec.yaml`: replace workspace resolution with `publish_to: none` and omit
  the promotional screenshot entry.
- `lib/src/widgets/selection_rects.dart`: adapt the visual rectangle merge pass
  from the local `pdfrx_og` selection fix into a shared extension, exported by
  `pdfrx.dart` for selection painting and newly created highlight annotations.
- `lib/src/widgets/pdf_viewer.dart`: paint those rectangles instead of each
  extracted fragment independently.

Generated space rectangles can be shorter than the actual distance between
words. Painting those fragments separately leaves holes in selected lines.
The merge pass joins contiguous text with compatible direction, line alignment,
and word-sized gaps. It preserves column gutters, line breaks, and partial-word
endpoints. It does not alter extraction, logical selection, hit testing,
clipboard contents, existing annotations, colors, or theme inversion. PoDoFo's
`HighlightRegion.fromTextRanges` uses the same rectangles for new PDF highlight
quadrilaterals, so their continuous line geometry persists through save/reopen.

Regression coverage lives in the app's `test/pdf_selection_geometry_test.dart`
and `test/pdf_selection_paint_test.dart`. The latter checks actual pixels and
clipboard output at 0, 90, 180, and 270 degrees. When upgrading pdfrx, check for
an equivalent upstream fix and run these tests before removing this backport.
`test/highlight_selection_test.dart` and `test/highlight_persistence_test.dart`
cover the annotation path, including native save/reopen and rendered word gaps.

Page-status changes invalidate both preview and partial image caches even when
page dimensions and rotation are unchanged. The engine uses these events for
annotation edits as well as page measurement; geometry alone cannot establish
bitmap validity. Pending renders for the changed pages are cancelled, including
previews awaiting image decoding, so stale work cannot overwrite the refresh.
`test/highlight_refresh_test.dart` checks creation, undo, and removal against the
stationary viewer's actual pixels in preview and partial-rendering modes.

## Staging fixes

`PdfViewerParams.onContextMenuDiagnostic` is an optional diagnostic observer for
secondary gesture recognition/cancellation/consumption, menu requests/builds,
selection-related suppression, and menu-anchor clearing. Observer errors are
isolated from interaction handling. It reports state and coordinates, never
document text, and leaves the existing gesture decisions unchanged. PoDoFo
connects it to the opt-in, bounded Debug-pane right-click trace.
`test/pdf_viewer_tap_test.dart` covers recognition, consumption and cancellation;
the app's context-menu tests cover tracing through rendering and delayed scans.

Ported from `pdfrx_og` staging at `fe80962214a3df7615c5f1a1917f6f26326fa661`:

- `9199451`: merge fragmented selection highlights (the geometry backport above).
- `2350da2`: dispatch taps without double-tap delay outside double-tap handlers,
  and notify selection clearing asynchronously without the 300 ms drag debounce.
- `fe80962`: distinguish URL/destination links from annotation-only entries in
  hit testing, cursor handling, default overlay painting, and accessibility.
  Annotation interaction remains available through `enableAnnotationInteraction`;
  custom painters and widget builders still receive all annotation metadata.

`PdfLinkNavigation.isNavigable` is exported as an extension, adapting the newer
engine member to the locked `pdfrx_engine` 0.6.1. This keeps the PDF engine and
PDFium versions unchanged. The default annotation overlay filter is applied to
2.6.5's painter; the newer upstream hover-color API is not part of these fixes.
PoDoFo's hover preview uses the same predicate to skip annotation-only entries.

`test/pdf_viewer_tap_test.dart` ports staging's mouse/touch, debounce, overlay,
double-tap, drag, and real-PDF link/annotation regressions and checks annotation
pixels, cursors, semantics, parameter updates, and custom rendering access.

The forked `lib/src/widgets/interactive_viewer.dart` excludes secondary-button
presses from its scale recognizer. An already-active trackpad pan/zoom could
otherwise claim a stationary right-click on release and prevent the context
menu from opening. A `RawGestureDetector` exposes the button filter while
retaining the existing scale callbacks, gesture settings, and trackpad options.
`test/pdf_viewer_tap_test.dart` checks short and longer right-clicks during both
trackpad pan and zoom, continued trackpad movement, and clicks after the gesture
ends. `test/pdf_pan_zoom_test.dart` covers primary mouse/touch panning and touch
pinching.
