# Target-aware previews: M4 progress

M4 is **in progress**. This first slice adds the bounded multipart compositor and
complex-object fixtures. Automatic grouping of these difficult targets,
evidence-driven second-page analysis, adaptive card layout, and the full M4
acceptance review remain unfinished. M5 qualification also remains open.

## Rendering foundation

The semantic renderer accepts one to four ordered rectangles on at most two
adjacent pages. It validates every rectangle before rendering and rejects
out-of-page, nonfinite, reversed-page, empty, or excessive selections. All slices
share a uniform scale and stack in target order, separated by eight logical
pixels. Fractional source boundaries round outwards to retain the full selection.
The compositor does not infer target membership or change reading order.

`LinkPreviewRequest.maxSize` bounds the semantic raster in logical pixels and is
included in the semantic cache key. The hard envelope is 480 by 360 logical
pixels, DPR at most two, and 960 by 720 pixels / 2,764,800 BGRA bytes. The existing
card still uses its 360 by 240 image box; wiring an adaptive card and its available
viewport into the request is part of the remaining M4 work. Contextual previews
retain their existing raster bounds.

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
targets that the eventual resolver should reject.

The layout rectangles are explicitly **hand annotations, not detector output**.
The compositor tests pass these selections directly to the renderer. They do not
demonstrate automatic resolution of the nine difficult objects. Existing M2
resolver tests continue to exercise actual recorded layout evidence independently.

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

Visual inspection of the separated panels, column continuation, narrow page
continuation, and rotated target confirms their required slices are present.
This is a raster review, separate from the remaining native-window acceptance
check and automatic target-quality review.

## Validation commands

On 2026-10-30, **68 focused regressions passed**, including the real bundled-model
lifecycle test. Dart analysis reported no issues, changed Dart files passed the
format check, and the macOS Debug app built and passed local signature
verification. PDF and JSON regeneration in a temporary directory reproduced
both files byte-for-byte. All 18 captured dirty-file hashes in the separate
Podoco worktree remain unchanged.

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
model lifecycle test (`PODOCO_PREVIEW_NATIVE=1`). Logs use the
`build/target-preview-m4-foundation-` prefix.

The remaining M4 changes must add conservative segmentation/grouping and
continuation evidence without treating these manual rectangles as model output.
They must then qualify target completeness, excluded neighbors, and adaptive
presentation together before marking M4 complete.
