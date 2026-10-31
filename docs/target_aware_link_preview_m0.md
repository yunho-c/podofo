# Target-aware previews: M0 baseline

The committed hover and Podoco features are integrated on
`feat/internal-link-hover` in `podofo-hover-previews`, following the user's
workspace choice. The locked macOS app builds and launches, and automated
baseline checks pass. M0's native-window demonstration of hover and Analyze is
still pending: Computer Use twice reported that PoDoFo access was not approved,
including after the user authorized enabling it. Do not count that gate as passed.
M1 semantic resolution has not started.

## Integration

- Hover baseline: `faeb1f4`; implementation-plan commit: `c719e5a`.
- Podoco baseline: `c668cd33a86b6d5bbcab321d7600f5b89d94a9ed`.
- Combined via a merge on the user-selected branch. The only textual conflict
  was pointer-down handling in `custom_pdf_viewer.dart`: retain unconditional
  hover dismissal, annotation-menu reset, and secondary-button hit testing.
- MLSR remains pinned to `0ca5d81bbcad0fa8a6274ebe3a7e44200bdc4da6`.
  That exact checkout was available locally, resolving the prior hover harness's
  dependency limitation. No substitute narration implementation was used.
- Dependency manifests and locks match the committed Podoco baseline. Models
  remain the bundled layout mixed-v1, FormulaNet M6, and MathCAT 0.7.7 M7 profile.
  No FP32 promotion or cloud-file branch merge is included.
- All 18 initially dirty/untracked files in the separate `podofo-podoco` worktree
  retained their captured SHA-256 contents after integration and validation.

## Fixtures and evidence

The deterministic three-page
[`linked_objects.pdf`](../podofo_frontend_one/test/fixtures/target_preview/linked_objects.pdf)
has six internal links with complete-target and excluded-neighbor rectangles.
All pages were rendered and visually reviewed. Repeated generation with
ReportLab 5.1.0 left both the PDF and manifest hashes unchanged.

The [real-paper manifest](../podofo_frontend_one/test/fixtures/target_preview/real_papers.json)
freezes eight links across MathReader and UniGVC. It covers numbered and
author/year bibliography entries, a multi-panel figure, adjacent figures sharing
one destination, a table, an equation, and a section opening. It records exact
PDF hashes, source rectangles/text, raw and normalized destinations, required
parts, and excluded neighbors. Target annotations were visually reviewed. This
is a development seed, not a held-out accuracy corpus.

Native tests validate the frozen metadata against PDFium and save contextual
crops. The Figure 4 and Figure 5 links in UniGVC really share a destination and
currently produce identical crops, mixing both figures and cutting their
captions. This confirms why the next milestones need source identity and complete
object bounds. No semantic accuracy claim is made for M0.

Local logs and captures are under
`podofo_frontend_one/build/target-preview-m0/` (ignored build artifacts).
The fixture README documents regeneration and corpus replay. The real PDFs
remain external; tests require `TARGET_PREVIEW_CORPUS_DIR` and fail on a hash
mismatch rather than silently accepting another revision.

## Validation on 2026-10-30

Environment: macOS Apple Silicon, Flutter 3.47.5 / Dart 3.13.4.

| Check | Result |
| --- | --- |
| Podoco preparation and offline enforced-lockfile dependency resolution | Passed |
| Full application `flutter analyze --no-pub` | No issues; subsequent fixture-test analysis also passed |
| Full macOS Debug build and local sandboxed signing | Passed |
| 49 focused tests | Passed: hover worker/native/overlay/reader, navigation, document leases, links/cache, analysis store/controls, bundled loader, equation controller, synthetic fixture |
| 17 real-model/native tests | Passed serially with a two-minute per-test timeout: actual Core ML layout/formulas, persistence, renderer ownership, cancellation, and reader overlay repaint |
| Synthetic and real-paper replay, 2 tests | Passed; synthetic case overlaps the focused run (67 distinct tests overall) |
| Bundled Podoco audit | Passed: 289 assets, 1,103,133,547 bytes, arm64 linkage and sandboxed signing |
| Native app launch | Process remained running; runtime log reports Metal Impeller and Dart VM initialization |
| Native-window hover + Analyze demonstration | Pending Computer Use access; automated reader/model evidence does not replace this gate |

The bundled catalog SHA-256 is
`afd5bf91a95a2c2c9da6c9b61bf1586e177faae24c81026b83aef422cc3a1b39`.
The signed bundled Podoco library SHA-256 is
`81da0444ab44d938958dfbcdaacda3fe093641f54a834a4355644c9a3cb467db`.
The local audit JSON retains component identities, native provenance, linkage,
and entitlements.

Initial failures were recorded before semantic implementation:

1. The plain `flutter test` invocation lacked PDFium/ObjectBox library paths.
   Using `tool/test_macos.py --build-mode debug` against the newly built bundle
   resolved those setup failures. The wrapper now accepts a build mode, retaining
   Release as its default and invoking the Dart VM directly so macOS preserves
   `DYLD_LIBRARY_PATH`.
2. Parallel real-model tests exceeded the runner's default 30-second limit.
   A serial run with `--timeout=2m --concurrency=1` passed all 17 in 43 seconds.
   No model or assertion changes were made to obtain that result.
3. The independently authored caption text used ordinary hyphens, while PDFium
   exposes discretionary hyphens as U+0002. The fixture metadata sanity check
   normalizes that marker; application text/resolver behavior is unchanged.
4. Xcode warned about unavailable/outdated iOS simulator support and the existing
   bundle identifier. These warnings did not prevent the macOS build or launch.

## Reproduce

From `podofo_frontend_one`, after the repository's normal pinned MLSR preparation:

```sh
python3 tool/prepare_podoco.py
flutter pub get --offline --enforce-lockfile
flutter analyze --no-pub
bash tool/build_macos_local.sh debug
python3 tool/test_macos.py --build-mode debug \
  test/link_preview_worker_test.dart test/link_preview_native_test.dart \
  test/pdf_link_hover_preview_test.dart test/reader_hover_preview_test.dart \
  test/reader_navigation_test.dart test/pdf_document_lease_test.dart \
  test/cache_and_links_test.dart test/analysis_store_test.dart \
  test/analysis_controls_test.dart test/bundled_analysis_test.dart \
  test/equation_controller_test.dart test/target_preview_fixture_test.dart

TARGET_PREVIEW_CORPUS_DIR=/path/to/frozen/pdfs \
  python3 tool/test_macos.py --build-mode debug test/target_preview_fixture_test.dart

PODOCO_M2_BUNDLE="$PWD/../podoco/model-assets/pp-doclayout-v3-m2-sandbox" \
PODOCO_M6_BUNDLE="$PWD/../podoco/model-assets/pp-formulanet-plus-l-m6" \
PODOCO_M8_PDF=/path/to/recognized-page.pdf \
  python3 tool/test_macos.py --build-mode debug -- \
  --timeout=2m --concurrency=1 \
  test/analysis_native_test.dart test/analysis_leases_test.dart \
  test/analysis_widget_test.dart
```

Use Flutter 3.47.5, passing its path through `FLUTTER_BIN` for the build wrapper
and `--flutter-sdk` for the test wrapper if it is not the configured SDK.
The explicit formula PDF used here has SHA-256
`e3bda3bdd501a74c26aad5fbf99595c419f5688843d716df8dd420115be8cab2`.
The model tests skip optional corpus/model cases when their inputs are absent;
those skips are not equivalent to the fully enabled run recorded above.

For the remaining window check, a separately identified sandboxed copy is at
`build/target-preview-m0/PoDoFo-M0.app` (`com.podofo.target-preview-m0`). It uses
its own container. Open the synthetic fixture, hover its links, click one and
return with Back. Enable Developer mode, open Debug, and run Analyze document
layout; confirm regions appear and hovering/clicking still works. This app's
access must be enabled in Computer Use before the automated native check can
continue. The ordinary user application and its data were not used for the probe.
