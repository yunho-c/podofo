# Target-aware previews: M4 complete-target grouping and presentation

M4 adds reference segmentation, bounded continuation across columns/pages,
multipart figure grouping, multiline equations, and an adaptive hover card.
Ambiguous or incomplete targets retain context. The compositor/fixture foundation
was committed separately as `34c2bdf`; this report distinguishes its raster
qualification from the completed resolver and reader checks. M5's held-out
accuracy, performance, stress and native-window qualification remains open.

## Resolution and continuation

References split at bracketed or dotted numbers and author-list boundaries,
using hanging indents to distinguish entries from continuation lines. Number-only
annotations can recover their immediate brackets; year-only annotations recover
their preceding author. Author matching checks the first author and exact year,
including letter suffixes, so coauthors and different editions do not alias.

Owned PDF glyph geometry recovers physical line breaks when PDFium joins a
discretionary hyphen across lines. It also restores caption line order on rotated
pages before matching labels. No PDF text or document content is changed.

Column transitions require the preceding column's last entry near the page bottom
and compatible leading text. A source-matched, unfinished last entry can request
exactly the following page through the existing coordinator. The first part is
never published alone. Continuation requires compatible text size, column geometry, bibliography
structure and a complete closing boundary. Missing leading regions, an ambiguous
boundary, or another unfinished page causes fallback; no third page is requested.
Generic text at the next page's top can qualify only immediately before another
recognizable bibliography entry. The evidence identity includes both pages.

Second-page text extraction uses a short PDF read lock. Repository/model waits
remain outside that lock, with the original request's cancellation, session and
revision checks. Warm page evidence uses the existing bounded cache and shared
analysis lane, without selecting either target page in manual Analyze.

Figures associate exact captions with distinct visual panels in a common band,
above or below the caption, accounting for rotated caption orientation. Closer
competing captions are excluded. Contained detector duplicates are removed.
Multiline equations grow through nearby aligned lines with mathematical
continuation operators, stopping at other equation numbers or intervening prose.
A safe union preserves the original spatial layout; if it includes an unrelated
region, individually safe ordered slices are used instead. Ambiguous groups or
groups exceeding four rectangles fall back.

## Rendering foundation

The semantic renderer accepts one to four ordered rectangles on at most two
adjacent pages. It validates every rectangle before rendering and rejects
out-of-page, nonfinite, reversed-page, empty, or excessive selections. All slices
share a uniform scale and stack in target order, separated by eight logical
pixels. Fractional source boundaries round outwards to retain the full selection.
The compositor does not infer target membership or change reading order.

`LinkPreviewRequest.maxSize` bounds the semantic raster in logical pixels and is
included in the semantic cache key. The hard envelope is 480 by 360 logical
pixels, DPR at most two, and 960 by 720 pixels / 2,764,800 BGRA bytes. The reader
passes its available viewport after card padding/header allowance into the
request. The whole card is at most 480 by 360 logical pixels and remains eight
pixels inside the viewport. Images preserve their aspect ratio; portrait cards
avoid reserving the full landscape width. Two-page targets show a page range.
Contextual previews retain their existing raster bounds.

Rendering retains one composite byte buffer and one source crop at a time.
Each source raster is disposed before the next render; cancellation listeners
detach after their crop. Missing, malformed, failed or cancelled slices discard
the entire composite. The worker retains its previously delivered context when
semantic rendering fails. Decoder buffers, codecs and descriptors are disposed
on every path. Returned images follow the existing caller/cache ownership rules.
The decoded LRU remains limited to 6 MiB and eight entries, so larger images
naturally reduce the retained entry count.

`PreviewRasterAccounting` records the composite and native crop payloads. Its
bound is one maximum composite plus one maximum crop (5,529,600 bytes). This is
not a process-memory bound: it excludes PDFium/model internals, decoder staging,
framework/GPU allocations, returned images, and the separately bounded LRU.

## Fixtures and scope of evidence

`complex_objects.pdf` contains six pages and eleven actual internal links.
Its manifest defines nine complete targets: numbered and author/year hanging
references, cross-column and adjacent-page references, separated figure panels,
a caption above its visual, a multiline equation, a section opening, and a
rotated/cropped figure. Two additional links describe ambiguous or unfinished
targets that the resolver must reject.

The layout rectangles are explicitly **hand annotations, not detector output**.
The compositor tests pass these selections directly to the renderer. Separately,
the resolver tests start from native source text and link destinations, use these
layout annotations, and resolve all nine complete objects while rejecting both
ambiguous/unfinished cases. Required native source-ink coverage is at least 99.5%
for every component, with zero covered ink in annotated unrelated neighbors.
These tests isolate grouping behavior; they do not establish detector quality.

The generator uses ReportLab 5.1.0 and pypdf 6.21.4. The PDF SHA-256 is
`8d5377176ef120a207e1398416574a476d5a2309927e15cd239913982108aaaa`.
Native checks verify the PDF identity, all links, text, page dimensions, displayed
destinations, CropBox/rotation conversion, and required/excluded boundaries.

At 1x, 2x, and a narrow 163 by 211 logical-pixel envelope requested at 4x
(capped to 2x), all 27 compositions match separately decoded native PDF crops
byte-for-byte. Tests include white gaps, channel order, placement, and every
pixel of each slice. The observed maximum final raster was 2,662,184 bytes;
the maximum accounted transient payload was 4,706,608 bytes and returned to
zero after every render. These are fixture observations within the hard bounds.
Paired contextual/composed PNGs and the raw report are retained under
`podofo_frontend_one/build/target-preview-m4/compositor/`.

Paired visual review covers all nine resolved fixture types, including narrow
multipart and rotated targets. Resolver crops and per-page inclusion/exclusion
metrics are retained in `build/target-preview-m4/resolved/`.

The actual bundled model is exercised independently through the application
coordinator. It resolves **7 of 9** complete complex targets: both hanging
reference formats, column/page continuation, the caption-above figure, multiline
equation, and section opening. All accepted targets retain required ink and
exclude annotated neighbors. The separated-panel and rotated-figure pages lack
the required visual detections and remain contextual; the resolver does not
invent missing figure bounds. The two ambiguous/unfinished cases also fall back.
All **14 existing development examples** (including the two real papers) continue
to resolve with complete required ink and zero annotated neighboring ink.

The cold cross-page case analyzes only pages 4 and 5. Across all eleven links,
the coordinator opens one layout engine and analyzes pages `[4, 5, 2, 3, 6]` once
each, with no formula engine. Native handles return to zero after disposal.
Every native result, including fallbacks, retains its source identity, reason,
parts, actual model snapshot, baseline/semantic PNGs and metrics under
`build/target-preview-m4/native-final/`. Older diagnostic captures are preserved
under `native-v1` and `native-v2`. These are development fixtures, not M5 held-out
measurements; evaluation duration includes capture/metric work and is not a
hover-latency benchmark.

## Reader behavior and lifecycle

Widget tests exercise 144 combinations of viewport edge, aspect ratio and density,
including light/dark cards, a narrow 240 by 180 viewport and an 80 by 80 viewport.
They verify full-image aspect ratio, whole-card bounds and pointer pass-through.
Representative captures with the actual bundled font are in
`build/target-preview-m4/widgets/`.

The integrated cross-page reader test verifies the page-range label, warm cache
reuse, unchanged viewport/history/visible analysis during hover, the original
clamped click destination, and Back restoration. The visible page label after a
bottom-of-page jump can belong to the following page; the test compares the actual
destination transform. Existing movement, tab/close, revision and navigation
regressions remain in place.

This test exposed deferred annotation loads in the vendored pdfrx painter that
could start after disposal. A generation guard now checks both before page access
and after extraction, preventing stale reads/cache writes. Optional annotation
read failures become empty entries until page invalidation. The local adaptation
and regression pointer are recorded in `third_party/pdfrx/PODOFO.md`.

## Validation commands

The foundation's 68-test run and signed build are recorded in the
`build/target-preview-m4-foundation-` logs. PDF and JSON regeneration in a
temporary directory reproduced both files byte-for-byte. The final M4 regression
run passed **148 tests**, with three optional corpus tests skipped (real formula
document qualification, renderer-corpus timing, and formula-prefix cancellation).
It covers the new resolver/continuation, reader, native-model and pdfrx tap
regressions; its log is `build/target-preview-m4-regression-final.log`.
The final analyzer reports no issues, the eleven changed application/test Dart
files pass formatting, and the pinned engine's 53 files plus lease patch verify.
The 18 recorded unrelated Podoco worktree files retain their original hashes.
The macOS Debug app built with Flutter 3.47.5, was signed locally, and passed
deep/strict signature verification (`build/target-preview-m4-build-final.log`).
Xcode's existing simulator-version and bundle-identifier warnings did not prevent
the macOS build. This is build qualification, not native-window acceptance.

Run from `podofo_frontend_one` with the pinned Flutter 3.47.5 SDK and built Debug
native libraries:

```sh
python3 tool/test_macos.py --build-mode debug -- --concurrency=1 --timeout=3m \
  test/preview_compositor_test.dart test/preview_compositor_native_test.dart
```

The controlled tests cover invalid limits, fractional boundaries, cancellation,
second-crop failures, malformed raster dimensions/payloads, cleanup before the
next crop, detached listeners, and the 6 MiB cache bound. Worker regressions also
check request-size propagation and distinct cache keys for width/height changes.
The focused regression run includes the M1/M2 resolver/worker tests, reader
hover/navigation tests, shared coordinator/storage tests, and the M3 real bundled
model lifecycle test (`PODOCO_PREVIEW_NATIVE=1`).

Add `test/complex_target_resolver_test.dart`, `test/pdf_link_hover_preview_test.dart`
and `test/reader_hover_preview_test.dart` for the grouping/presentation path.
Set `TARGET_PREVIEW_M4_RUN` to a new suffix for
`test/complex_preview_native_test.dart`; it refuses to overwrite an existing
capture directory. The actual-model test requires all seven previously qualified
targets to resolve, so universal fallback cannot pass. Use the M2 corpus/model
environment for `test/target_preview_evaluation_test.dart`.

M5 must qualify independent held-out documents and actual native-window behavior.
Detector omissions, unsupported labels, weak bibliography boundaries, and targets
larger than the two-page/four-part budget remain explicit fallback cases.
