# Target-aware previews: M2 cached semantic targets

M2 refines internal-link previews using cached Podoco regions and owned native
PDF text. The contextual raster appears first; a still-current hover receives at
most one semantic replacement with a supported label. An ambiguous or incomplete
match keeps the contextual image. Rendering remains bounded to 360 × 240 logical
pixels, with density capped at 2.

## Resolution rules

The deterministic resolver combines the source link's number or author/year,
the target page and destination neighborhood, native region subtypes, text, and
geometry. It distinguishes Figure 4 and Figure 5 even when they share the same
PDF destination. Detector scores are not interpreted as identity confidence.

- Numbered references stop at the next numbered entry. Author/year references
  require a uniquely matching entry region. Completion requires terminal
  punctuation and space from the page edge.
- Figures and tables require a matching caption and a uniquely associated
  visual. Contained duplicate detections collapse; competing nearby visuals
  cause fallback. The crop contains both the visual and caption.
- Equations require a matching number and one aligned display-formula region.
  No transcription or MathCAT work is needed.
- Sections include the matching heading and its nearest aligned opening text
  block. Ambiguous or apparently unfinished blocks cause fallback.

Conflicting identities, missing/truncated text, missing layout, competing
candidates, and unions containing unrelated detected regions are unresolved.
Explicit FitR behavior remains unchanged. This milestone supports complete
single-page targets; multipart and continuation handling remain M4 work.

## Integration and ownership

`preview_text.dart` holds the owned text contracts independently of session IO.
`PdfLinkContext` passes them and compatible cached evidence to the resolver.
The worker renders the semantic crop under a separate short PDF read lock on
its existing one-active/latest-pending lane. Source identity, resolver version
2, layout evidence, bounds, revision, and density participate in semantic cache
keys. Callers receive image clones; reset disposes cache ownership separately.
Cache transfer precedes the callback so a callback-triggered reset cannot
repopulate a cleared cache.

M2 uses only the configured manual-analysis identity. After a cold restart,
missing configuration or layout retains context. Hover does not initialize
models or change visible analysis state. M3 adds bounded on-demand layout and
its separate persistence namespace.

## Validation

On 2026-10-30, **92 distinct tests passed**: the 90-test reader/analysis regression
run, the added parent-versus-subsection identity regression, and the actual-model
development evaluation. The final focused run passed all 15 tests. Full Flutter
analysis reported no issues; the final macOS Debug app built and signed locally
(`target-preview-m2-final-build-retry.log`). All 53 vendored renderer files and their patch
remain verified, and all 18 captured dirty-file hashes in the separate Podoco
worktree are unchanged. Model/dependency pins are unchanged.

The six synthetic links and eight frozen real-paper links all resolved to their
intended kinds. Every annotated required source pixel was covered, and no
annotated neighboring ink was included. The real-paper set includes numbered
and author/year citations, figures, a table, an equation, and a section opening.
The two figures with an identical destination resolve to different objects.
These are development fixtures, not a held-out accuracy claim.

Actual layout-only inference was captured for seven target pages using the
committed mixed layout profile. Two synthetic layout snapshots are tracked for
model-free resolver replay. All 14 baseline/semantic pairs and complete runtime
region/provenance snapshots are retained in
`podofo_frontend_one/build/target-preview-evaluation/m2/`; the semantic crops were
visually reviewed. Native model handles returned to zero after evaluation.
The fixture README documents reproducible capture commands and coverage rules.

New tests cover required/excluded pixels, bounded rendering, page-only identity,
missing evidence, ambiguous/multiple source labels, truncated text, contextual
delivery before refinement, exact section numbering, semantic raster reuse, caller ownership after
reset, reentrant reset, and cancellation/edit/close during cache reads.

Validation commands, from `podofo_frontend_one` with Flutter 3.47.5 / Dart 3.13.4:

```sh
flutter analyze --no-pub
python3 tool/verify_pdfrx_engine.py
python3 tool/test_macos.py --build-mode debug -- --concurrency=1 --timeout=2m \
  test/link_target_resolver_test.dart test/link_resolution_foundations_test.dart \
  test/target_preview_fixture_test.dart test/link_preview_worker_test.dart \
  test/link_preview_native_test.dart test/pdf_link_hover_preview_test.dart \
  test/reader_hover_preview_test.dart test/reader_navigation_test.dart \
  test/pdf_document_lease_test.dart test/cache_and_links_test.dart \
  test/analysis_store_test.dart test/analysis_controls_test.dart \
  test/bundled_analysis_test.dart test/equation_controller_test.dart \
  test/analysis_native_test.dart test/analysis_leases_test.dart \
  test/analysis_widget_test.dart
bash tool/build_macos_local.sh debug
```

Corpus/model paths match M1; the evaluation additionally uses
`TARGET_PREVIEW_RUN=m2`. Logs are `build/target-preview-m2-*.log`. M0's
native-window hover/Analyze acceptance remains pending Computer Use access.
Automated reader tests and a successful build do not close that separate gate.
The later adaptive-size work is also needed for readability of long narrow
entries at this milestone's fixed card envelope.

One evaluation attempt crashed in native PDFium while an app build was also
running. The crash was in `CPDF_ColorSpace::GetStockCS`; the cause is not
established. The identical focused suite passed when rerun after build activity
finished. A subsequent Xcode project-list invocation exited with signal 9;
that interrupted invocation is not passing build evidence. The failed logs are
retained alongside the successful runs.
