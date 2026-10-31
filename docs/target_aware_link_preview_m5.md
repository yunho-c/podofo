# Target-aware previews: M5 qualification in progress

M5 is not complete. The latency/ownership harness now exercises the real bundled
layout engine, and a model-independent paper corpus has been sampled. Held-out
target accuracy and native-window acceptance remain unqualified.

## Cache preparation latency

The first measurement found that a fresh persisted-layout hit took p95 247.8 ms,
above the 150 ms cached-preview target. Profile inspection rehashed model payloads
even when only persisted results were needed. The loader now exposes a separate
`readLayoutIdentity` operation: it verifies the pinned catalog and bounded YAML
manifest, then returns model/profile/adapter/backend metadata for cache comparison.
The existing snapshot checks still require exact model manifests, document identity,
render profile, compute policy and compatible pipeline provenance.

This metadata object cannot open an analyzer. Full native payload verification
remains in `verifyLayout` and `openAnalyzer`. Custom model directories have no
application-pinned catalog and retain their full verification path even for
profile inspection. Native tests establish that a catalog plus valid manifest
can identify cached results, while missing payloads still prevent both inference
and custom-directory verification. Corrupt/oversized manifests, changed catalog
pins, unsupported platforms and symlinked components remain rejected.

The final performance run so far is `performance-v3`, on an Apple M4 Pro with
48 GiB RAM, macOS 27.0.1 (26A434), Flutter 3.47.5 / Dart 3.13.4, using the bundled
experimental mixed layout profile and the existing linked-object Figure 4 at 2x.
These are fixture observations, not a corpus-wide or release-mode benchmark.

| Path | Samples | Semantic p50 | Semantic p95 | Context p95 |
| --- | ---: | ---: | ---: | ---: |
| Decoded image and text reuse | 30 | 1.4 ms | 1.9 ms | 0.14 ms |
| Persisted layout, fresh worker/coordinator | 20 | 6.9 ms | 10.1 ms | 1.3 ms |
| Warm model, forced layout miss | 20 | 69.0 ms | 77.2 ms | 1.4 ms |
| Cold app preparation | 20 | 605.9 ms | 639.2 ms | 1.8 ms |

Timing begins at `LinkPreviewWorker.load` and ends at the contextual future or
semantic callback; it excludes the 350 ms hover debounce, captures and assertions.
Cold means a fresh worker, coordinator and empty layout directory with the PDF
already open. The process, OS page cache and Core ML compilation cache remain
warm. Decoded-image/text reuse still reads layout provenance from disk; it is
not a disk-free path. New inference is counted explicitly, so a purported warm
analysis sample cannot pass by accidentally reusing persisted layout.

The initial failing run remains under `build/target-preview-m5/performance-v1/`;
`performance-v2` and `performance-v3` retain every subsequent raw sample. Both
cached paths pass the p95 150 ms gate. Cold preparation continues to deliver the
contextual image first; no inference deadline has been inferred from this sample.

## Cancellation and ownership

The native stress run performs 100 requests: 25 immediate cancellations,
25 cancellations after the contextual image, 25 cancellations while a real
renderer input lease is held, and 25 completed hovers across all six fixture
targets at varying densities. The completed sequence retains caches between
requests and reaches the eight-entry decoded-image bound, exercising eviction.

After every drained cycle, native handles return to the single warm layout
engine and renderer input bytes return to zero. After disposal, handles, retained
decoded bytes and text bytes are zero. Observed peaks are 6,279,564 decoded bytes
(limit 6 MiB), eight images, 86,064 text bytes on three pages (limits 4 MiB/eight
pages), and 12,192 layout-cache bytes (limit 16 MiB). These account for owned
payloads/caches, not process RSS, model weights or framework/GPU allocations.
The revision and navigation history remain unchanged.

Run from `podofo_frontend_one`, using a fresh evidence suffix:

```sh
TARGET_PREVIEW_QUALIFICATION_RUN=my-run PODOCO_PREVIEW_NATIVE=1 \
  python3 tool/test_macos.py --build-mode debug -- --concurrency=1 --timeout=5m \
  test/preview_qualification_native_test.dart test/bundled_preview_identity_test.dart
```

The combined focused run passed 64 tests, including loader metadata checks,
real bundled-model lifecycle, coordinator/store behavior, complex resolution,
reader hover and M1 foundation regressions. See
`build/target-preview-m5-performance-v3.log` and the raw JSON under
`build/target-preview-m5/performance-v3/`.

The subsequent full Flutter run passed **379 tests with 18 opt-in skips**
(`build/target-preview-m5-full-test.log`). The real M5 benchmark, payload guard
and M3 model lifecycle were exercised in the separate focused run. Analysis and
format checks pass, and the macOS Debug build passed local deep/strict signature
verification (`build/target-preview-m5-build.log`). The 53-file pinned native
engine check passes. All 18 recorded unrelated Podoco worktree files retain
their original hashes. No Rust/C implementation or ABI changed in this slice.

## Independent corpus preparation

`test/fixtures/target_preview/m5_sampling.json` fixes twelve new documents, split
six/six between development and held-out review. Selection takes the first two
distinct named targets per group in PDF page/annotation order, plus the first
footnote as an unsupported control when available. This is a bounded convenience
sample of the local paper collection, not a random population sample.

The prepared sample has 102 links: 53 development and 49 held-out. Held-out
groups currently contain twelve citations, twelve figure/table links, eleven
equations and eleven sections, plus three controls. Eligibility and full target
boundaries still require source review; these counts are not eligible coverage
denominators. The two existing real-paper development seeds add eight links,
bringing the intended total to 110 links over fourteen papers.

`tool/prepare_target_preview_corpus.py` reads links, renders full source/target
pages and exports independent text geometry. It does not invoke the resolver or
detector. Preparation used PyMuPDF 2.0 and refuses to overwrite a run directory.
Named destination coordinates
are converted from raw PDF space to displayed page space, including page transforms.
The reviewed annotation files live under `test/fixtures/target_preview/m5_annotations/`.
The first development paper has nine reviewed cases, including one unsupported
control; no new paper's resolver output has been examined yet.

The initial sampling baseline is resolver version 3 at `1a31463`. Development
may still change the resolver. Freeze its final identity and all eligibility
annotations before any held-out run; a held-out document that drives a change
must move to development and be replaced. Do not classify Roman labels or
multi-citation source fragments as ineligible merely because current rules fail.
PDFs stay local because redistribution licenses have not been reviewed; retain
their hashes and source URLs instead of committing source documents.

## Remaining acceptance work

Complete annotation and development replay, freeze rules, and evaluate every
held-out link with paired images, required/excluded pixel metrics and per-group
coverage. Inspect all failures against the original zero-wrong-object, 8-of-10
coverage and 90% completeness gates. Exercise the additional synthetic fallback
cases and retain the final full-regression/build evidence.

Computer Use was retried after the user's earlier authorization but still
returned `Computer Use was not approved to use PoDoFo`. Native-window edge,
HiDPI, appearance, navigation, save, selection/narration and close checks remain
open. Automated widget/native-library checks do not establish that acceptance.
