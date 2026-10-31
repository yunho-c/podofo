# Target-aware previews: M1 resolution foundations

M1 adds owned resolution inputs, native destination-presence handling, bounded
PDF text evidence, and read-only offscreen layout access on
`feat/internal-link-hover`. Explicit FitR destinations produce an `explicitArea`
result. Point and page-only destinations deliberately remain unresolved and keep
the existing contextual image and page label. Object identity matching is M2;
on-demand inference and layout-only persistence are M3.

## Data flow and contracts

The viewer captures a `LinkPreviewRequest` before asynchronous work: session,
revision, source page, annotation index/rectangles, compact destination, and
bounded render density. Source identity participates in contextual image keys;
`ResolvedLinkTarget.cacheKey` additionally includes resolver version, evidence
identity, match tier, kind, selected page rectangles, and density. Two source
links sharing a destination therefore cannot share a semantic identity.

`LinkPreviewWorker` publishes the contextual raster first, then prepares evidence
on its existing one-active/latest-pending lane. `PdfLinkContext` reads owned text
and geometry in separate session read-lock scopes, reads layout from disk outside
the PDF lock, and calls the pure resolver. It rechecks cancellation, ownership,
and revision across stages. No additional image replacement occurs in M1.
The worker exposes its current prepared result for the next resolver milestone;
that result becomes unavailable after cancellation, revision change, or close.

`PreviewDestination` uses displayed-page PDF points with nullable axes. The
shared adapter subtracts the raw page bounding-box origin and applies rotation
once. Missing axes remain missing after rotation; the renderer may use a center
only for its contextual crop. FitR evidence is clipped to the page without
semantic padding; rendering retains the existing 12-point padding and raster
limits. Uncertain FitH/FitV coordinates supply no semantic evidence in M1.

The vendored native parser now uses `FPDFDest_GetLocationInPage` for XYZ values.
Coordinate zero and absent coordinates stay distinct. PDFium treats zoom zero as
no zoom change; failed XYZ reads yield unknown coordinates. The existing native
ABI and dependency versions are unchanged. The reviewed patch and integrity
manifest reproduce all 53 vendored files from the hash-verified upstream source,
including the local extension documentation.

## Text and layout evidence

`PdfTextSnapshot` retains original UTF-16 offsets and raw rectangles without
narration filtering. Displayed rectangles select source glyphs; whitespace
between selected glyphs is preserved even when PDFium gives it empty boxes.
Source spans include their offsets and rectangles, at most 2,048 UTF-16 units,
256 units of context per side, and an explicit truncation flag. Budget boundaries
avoid splitting surrogate pairs. Disjoint selections remain separate spans.

The text LRU retains at most eight pages and 4 MiB of accounted payload: UTF-16
text and both raw/displayed four-double rectangles. This is not a Dart heap or
native extraction-memory limit. Pages exceeding 200,000 UTF-16 units or the
accounted page budget are unavailable for matching. Copy restrictions and failed
extractions leave the contextual preview usable. Source and target text remain
owned values after the PDF lock is released.

`AnalysisController.previewIdentity` captures the existing configured analysis
identity without opening an engine. `PreviewLayoutRepository` calls only
`AnalysisStore.read`; it never selects a page, changes equation state, initializes
models, writes snapshots, or notifies the controller. A missing configured
identity is a cache miss, including immediately after a cold restart. M1 does not
scan disk for other profiles. Returned evidence retains complete analysis,
model/artifact, compute, render, and reading-order provenance. A layout-ready
snapshot can be used before formulas finish. Document/profile mismatch, corrupt
cache, changed revision, and incompatible page dimensions produce no evidence.

## Validation

Validated on 2026-10-30: **77 distinct tests passed** across the combined
76-test run and final focused reruns with the additional published-evidence
invalidation test. All 14 frozen links pass source-text/coordinate replay.
Actual glyph pixels confirm text geometry across all four rotations. Full Flutter
analysis reported no issues; the final macOS Debug app built and signed locally.
Renderer integrity and exact-upstream patch replay passed. Dependency/model pins
are unchanged, and all 18 captured dirty-file hashes in the separate Podoco
worktree still match. The existing Xcode iOS-simulator warnings remain nonfatal
for this macOS build.

Commands run from `podofo_frontend_one` using Flutter 3.47.5 / Dart 3.13.4:

```sh
flutter analyze --no-pub
python3 tool/verify_pdfrx_engine.py
python3 tool/test_macos.py --build-mode debug -- --concurrency=1 --timeout=2m \
  test/link_resolution_foundations_test.dart test/target_preview_fixture_test.dart \
  test/link_preview_worker_test.dart test/link_preview_native_test.dart \
  test/pdf_link_hover_preview_test.dart test/reader_hover_preview_test.dart \
  test/reader_navigation_test.dart test/pdf_document_lease_test.dart \
  test/cache_and_links_test.dart test/analysis_store_test.dart \
  test/analysis_controls_test.dart test/bundled_analysis_test.dart \
  test/equation_controller_test.dart test/analysis_native_test.dart \
  test/analysis_leases_test.dart test/analysis_widget_test.dart
bash tool/build_macos_local.sh debug
```

The corpus/model runs set `TARGET_PREVIEW_CORPUS_DIR`, `PODOCO_M2_BUNDLE`,
`PODOCO_M6_BUNDLE`, and `PODOCO_M8_PDF` to the same frozen inputs documented in
[M0](target_aware_link_preview_m0.md). Supply `--flutter-sdk` to the test wrapper
and `FLUTTER_BIN` to the build wrapper when the pinned SDK is not selected.
Logs are `build/target-preview-m1-*.log`.

The new tests cover null versus zero, all rotations and cropped origins, FitR,
malformed and partial destinations, original text offsets and surrogate pairs,
limits and eviction, source/evidence cache identities, progressive offscreen
reads, unchanged visible state and cache bytes, and cancellation/edit/close during
cache IO. A PDF read/close completes while cache IO is blocked, demonstrating
that the repository does not hold the session lock. Corpus replay now checks
source text and normalized destinations for all six synthetic and eight real
links, including the two figures sharing one destination.

The reader widget harness now pumps fake timers while draining native work after
the first raster arrives. Its previous `runAsync` wait could stall a PDFium job
started in the fake-timer zone by post-raster preparation. This changes test
scheduling, not production cancellation or timeout behavior.

M0's native-window hover/Analyze acceptance remains pending Computer Use access.
Automated widget/native results and a macOS build do not close that separate gate.
