# Target-aware previews: M5 qualification in progress

M5 is not complete. The latency/ownership harness now exercises the real bundled
layout engine, and the first frozen held-out evaluation is complete. It failed
section coverage and completeness gates. Three papers have moved to development
before resolver changes; the held-out set needs replenishment. Native-window
acceptance also remains unqualified.

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

The initial prepared sample had 102 links: 53 development and 49 held-out. Held-out
groups contain twelve citations, twelve figure/table links, eleven equations and
eleven sections, plus three controls. Source review confirmed all 46 named targets
as eligible; the three footnotes are unsupported controls. The two existing
real-paper development seeds add eight links,
bringing the intended total to 110 links over fourteen papers.

`tool/prepare_target_preview_corpus.py` reads links, renders full source/target
pages and exports independent text geometry. It does not invoke the resolver or
detector. Preparation used PyMuPDF 2.0 and refuses to overwrite a run directory.
Named destination coordinates
are converted from raw PDF space to displayed page space, including page transforms.
The reviewed annotation files live under `test/fixtures/target_preview/m5_annotations/`.
All six development papers have 53 reviewed cases: 48 eligible targets and five
unsupported controls. Each document's annotations were completed before its
resolver output was examined. All six held-out papers now have independently
reviewed source annotations, also completed before any resolver/model output.

The initial sampling baseline is resolver version 3 at `1a31463`. Development
may still change the resolver. Freeze its final identity and all eligibility
annotations before any held-out run; a held-out document that drives a change
must move to development and be replaced. Do not classify Roman labels or
multi-citation source fragments as ineligible merely because current rules fail.
PDFs stay local because redistribution licenses have not been reviewed; retain
their hashes and source URLs instead of committing source documents.

## Initial development replay

`test/paper_preview_qualification_test.dart` captures every selected annotated
link through the actual PDF text, bundled layout, resolver and crop paths. It
retains context and semantic images, source context, evidence identity, selected
parts, timings, and required/excluded pixel metrics. Metrics include annotated
pages absent from the selected result, so omitting a continuation page cannot
pass completeness. Failures and fallbacks remain in `results.json`; native
handles must return to zero after each document. Development runs reject wrong
or incomplete accepted targets but permit conservative fallbacks.

Held-out runs require the complete split and a matching `m5_freeze.json` containing
the annotation and measured pipeline source hashes before any native evaluation
begins. The first freeze uses resolver version 7 and the annotations described
below. A passing development run is not a held-out accuracy qualification.

The initial replay identified citation-list punctuation, line breaks in author
names, ditto-author bibliography entries, and numeric appendix references as
avoidable fallbacks. Resolver version 4 handles these forms. Ditto entries inherit
only the author identity from a nearby preceding entry in the same column, keeping
each entry's year and crop separate. Missing/distant predecessors, multiple linked
years and mismatched year suffixes still fall back. Regression tests also preserve
year-only links following an opening parenthesis.

The fresh native run `papers-commit-dev-v3` evaluated the reviewed links in
`1802.01436v2` and `2003.01966v7`, with the following development-only results:

| Group | Eligible | Resolved | Complete and excludes annotated neighbors |
| --- | ---: | ---: | ---: |
| Citations | 4 | 4 | 4 |
| Figures/tables | 4 | 4 | 4 |
| Equations | 4 | 4 | 4 |
| Sections | 4 | 2 | 2 |

Both unsupported footnote controls remain contextual. There were no reported
wrong-object or completeness failures among the accepted targets, and native
handles returned to zero. The two section fallbacks remain eligible: one opening
paragraph continues onto the following page (`noCompleteMatch`), and another
selection would include neighboring content (`regionsContainNeighbor`). The new
ditto-author, wrapped author/year and appendix crops were also visually reviewed.
The focused run passed 34 tests; previous failing development captures remain
available, including the parenthesized-year regression found and fixed before
this commit.

Run the reviewed development subset from `podofo_frontend_one` with a fresh suffix:

```sh
TARGET_PREVIEW_M5_RUN=my-dev-run \
  TARGET_PREVIEW_M5_DOCUMENTS=1802.01436v2,2003.01966v7 \
  TARGET_PREVIEW_CORPUS_DIR=/path/to/local/pdfs \
  python3 tool/test_macos.py --build-mode debug -- --concurrency=1 --timeout=5m \
  test/reference_identity_test.dart test/complex_target_resolver_test.dart \
  test/link_target_resolver_test.dart test/paper_preview_qualification_test.dart
```

Omitting `TARGET_PREVIEW_M5_DOCUMENTS` requires annotations for the entire selected
split. `TARGET_PREVIEW_M5_SPLIT=held_out` enables the freeze and coverage gates;
it rejects document filtering. `TARGET_PREVIEW_M5_REPLAY` can point to a prior run
directory to copy its actual layout-cache JSON into a fresh output directory;
normal provenance checks still apply. The run above used fresh layout inference.

The commit verification also passed the full Flutter suite (379 passed, 21 opt-in
skips), static analysis, formatting, and the 53-file pinned-engine check. The
original fourteen synthetic/real-paper targets passed a separate fresh native
evaluation (`build/target-preview-evaluation/m5-commit-regression/`). Full-suite
and focused logs use the `build/target-preview-m5-commit-` prefix. All eighteen
recorded unrelated Podoco worktree files still match their original hashes.
The macOS Debug app also built and passed local deep/strict signature verification
(`build/target-preview-m5-commit-build.log`). Native tests and building/signing ran
serially. This build does not establish native-window acceptance.

## Full development set and multipart figure correction

The first six-document run, `papers-all-dev-v1`, exposed a clipped accepted figure:
the two bottom plots and main caption were selected, while the two top plots and
panel labels were missing. Detector-provided `(a)`/`(b)` captions had competed with
the numbered figure caption, and grouping considered only the nearest row.

Resolver version 5 distinguishes panel labels from numbered captions and follows
adjacent visual rows/columns, stopping at intervening prose/headings or competing
numbered captions. It includes panel labels in the selected components and rejects
groups beyond eight detected visuals. This internal grouping limit does not change
the renderer: crops still require a safe union or at most four parts within the
existing pixel/memory bounds. The four-panel case, paired photographs with labels,
and a competing numbered caption now have blocking geometry regressions.

The follow-up `papers-all-dev-v2` reuses the first run's actual model cache through
normal provenance checks and rerenders all 53 links. It passed the development
acceptance checks, with these counts:

| Group | Eligible | Resolved | Complete and excludes annotated neighbors |
| --- | ---: | ---: | ---: |
| Citations | 12 | 6 | 6 |
| Figures/tables | 12 | 11 | 11 |
| Equations | 12 | 7 | 7 |
| Sections | 12 | 3 | 3 |

All five unsupported controls fall back. No accepted target failed the annotated
wrong-object/completeness checks; native handles returned to zero. The corrected
four-panel image was visually checked against the source page. The focused run
passed 35 tests. Failed captures remain retained, and the freeze identity now
includes `figure_targets.dart` as part of the resolver implementation.

These results demonstrate substantial remaining coverage gaps, not release
qualification. Development failures include individually linked citation-list
fragments, shared-author years, Roman/appendix labels, equations competing with
another column, and section text blocks that end with a colon or continue across
a page. Eligibility has not been reduced to hide those cases. Held-out annotations
and evaluation remain pending.

The panel correction passed the full Flutter suite (382 passed, 21 opt-in skips),
the original fourteen-target native evaluation, static analysis, formatting and
the pinned-engine verification. Logs use `build/target-preview-m5-panels-`; the
original-target artifacts are under
`build/target-preview-evaluation/m5-panels-regression/`.
The macOS Debug build and deep/strict local signature verification passed
(`build/target-preview-m5-panels-build.log`). All eighteen preserved unrelated
Podoco files still match their recorded hashes.

## Source identity in lists and named labels

Resolver version 6 recognizes a single annotated member inside a well-formed
bracketed citation list, including when other members are ranges. It requires
member boundaries on both sides: a selected range, a range endpoint, multiple
selected numbers, malformed context and a truncated list remain unresolved.
The previous fixture treating an individually linked `31` within `[30, 31]` as
ambiguous now expects reference 31; an annotation spanning `30, 31` still rejects.

Author-only links can include an opening bracket, and a year-only link can inherit
the immediately preceding author across a comma-separated year list. It does not
cross semicolon-separated entries or borrow the earlier year. Plural named
prefixes carry across contiguous comma-separated labels, so the second individually
linked number in `Eqs. 1, 2` remains an equation. Roman and appendix labels are
matched explicitly; multiple labels under one annotation remain ambiguous.
Source parsing lives in `source_identity.dart`, which is included in the freeze
identity alongside the rest of the resolver.

The 53-link `papers-labels-dev-v4` replay passed with 11/12 citations, 12/12
figures/tables, 9/12 equations and 3/12 sections resolved. Every accepted result
passed the required/excluded ink checks; all five unsupported controls fell back
and native handles returned to zero. New citation-list and Roman-table crops were
visually reviewed. The focused run passed 41 tests. One author/year reference
still has competing matches; the remaining equation and section failures require
grouping work. These remain development observations, with no held-out run yet.

The source-identity changes also passed the full Flutter suite (386 passed,
21 opt-in skips), the original fourteen-target native evaluation, static analysis,
formatting and the pinned-engine check. Logs use
`build/target-preview-m5-labels-`; original-target captures are retained under
`build/target-preview-evaluation/m5-labels-regression/`.
The Debug app built and passed local deep/strict signature verification
(`build/target-preview-m5-labels-build.log`). A final fixture-only replay passed
all nine cases after making the hand-built page/image metadata consistent. All
eighteen preserved unrelated Podoco files remain unchanged.

## Equation ownership and complete section openings

Resolver version 7 excludes a vertically aligned formula in another column when
that formula has its own closer equation number in its text direction. Equal-gap
matches remain ambiguous. Section grouping now supports centered headings,
complete opening text blocks ending in a colon, and inline-formula extents owned
by the paragraph.

An unfinished opening block at the bottom of its column can request only the next
page. Continuation requires first-column body text with compatible font and width,
a lowercase start and a complete ending; intervening headings, text in a later
column on the same page, wrong page identity, or a still-unfinished continuation
retain the contextual preview. The result stays
within four parts across two adjacent pages. Section resolution is included in the
qualification freeze identity through `section_targets.dart`.

Crop padding now stops before neighboring model regions and can shrink from three
points to one or zero, without shrinking selected content. This fixes a development
failure where the next paragraph leaked 32 pixels into an otherwise complete
two-page section preview. The failing capture remains in `papers-grouping-dev-v6`.
Regression cases cover paired equations across columns, centered/colon headings,
inline mathematics, dense paragraph spacing and bounded continuation.

The final 53-link `papers-grouping-commit-v9` replay passed with 11/12 citations and 12/12
in each of figures/tables, equations and sections resolved. Every accepted target
passed required/excluded ink checks; all five unsupported controls fell back and
native handles returned to zero. The focused run passed 47 tests, including the
original fourteen-target native evaluation. The two
cross-page section crops and the tight appendix/equation crops were visually
reviewed. The remaining citation fallback has competing author/year matches.
These are development results; held-out qualification remains pending.

The full Flutter suite passed 391 tests with 21 opt-in skips. After the final
same-page column guard, all focused resolver suites, the complete development
replay and the original fourteen-target native evaluation passed again. Static
analysis, formatting and the 53-file pinned-engine check pass. Test and analysis
logs use `build/target-preview-m5-grouping-`; original-target captures are under
`build/target-preview-evaluation/m5-grouping-regression/`. All eighteen preserved
unrelated Podoco files retain their recorded hashes.

The macOS Debug build and deep/strict local signature verification passed
(`build/target-preview-m5-grouping-build.log`). Native tests and building/signing
ran serially. This does not establish native-window acceptance.

## First held-out source freeze

All 49 held-out links were reviewed from full source/target page renderings and
independent MuPDF text geometry before examining any resolver or model output.
Their 160 required/excluded rectangles were checked against the original PDF
hashes, page bounds and source ink. No required rectangle overlaps an excluded
rectangle for the same link. All 46 named targets remain eligible, including
compound section labels, nested headings, a cross-column opening paragraph,
equation underbraces, table notes and a panel-qualified figure link.

The annotation policy includes the complete figure and shared caption when a
panel-qualified source points to the PDF destination for that figure. Section
openings include an immediately intervening subsection heading before the first
paragraph. Displayed mathematics following a colon-ended opening text block is
separate; inline mathematics belongs to that block. Bibliography back-references
and figure/table notes belong to their complete target.

The first freeze records 34 hashes: six annotation
files and the resolver, extraction/rendering/analysis pipeline, scoring harness,
sampling manifest, dependency lock, loader and bundled model identity. The
evaluation checks the whole frozen held-out split before opening native analysis.
The source baseline is `0f10834`; changes motivated by these held-out documents
require moving the affected documents into development and replenishing them.
The original freeze and sampling manifest are retained in
`test/fixtures/target_preview/m5_history/held_out_v1_{freeze,sampling}.json`.

## First held-out evaluation: failed

The first frozen run used commit `4c18a6b` and fresh native model inference. All
49 links were captured, including every fallback and unsupported control. The
results and per-link metrics are retained in
`test/fixtures/target_preview/m5_history/held_out_v1_results.json`; full context
and semantic images remain local under `build/target-preview-m5/papers-held-out-v1/`.

| Group | Eligible | Resolved | Complete and excludes annotated neighbors |
| --- | ---: | ---: | ---: |
| Citations | 12 | 12 | 12 |
| Figures/tables | 12 | 10 | 10 |
| Equations | 11 | 9 | 9 |
| Sections | 11 | 8 | 6 |

All three unsupported controls stayed contextual, and native handles returned to
zero. The automatic wrong-object checks reported zero flags; this is not a
completed visual audit of all accepted crops. Sections fail both the 80 percent
eligible coverage gate (8/11) and the 90 percent resolved completeness gate (6/8).
The test intentionally failed (`build/target-preview-m5-held-out-v1.log`).

Visual inspection confirmed that two accepted section previews dropped an
intervening subsection heading while showing the parent heading and opening
paragraph. Three compound section labels also fell back. Before any resolver
changes, the complete `2111.13850v2`, `2212.01330v1` and `2312.02753v1` documents
were promoted to development. Their eligibility and required/excluded boundaries
are unchanged. These failures will become blocking regressions. The original
freeze is archived, and there is no active `m5_freeze.json` until replacement
documents are source-reviewed and the revised pipeline is frozen.

Remaining conservative fallbacks include a Roman table, a panel-qualified figure,
a forward equation row among independently numbered rows, and an equation link
whose source punctuation prevents unique classification. These results are
reported as failures/fallbacks, not excluded from the coverage denominators.

## Remaining acceptance work

Fix the promoted section regressions, replenish the three held-out papers, and
freeze and evaluate every held-out link with paired images, required/excluded pixel metrics and per-group
coverage. Inspect all failures against the original zero-wrong-object, 8-of-10
coverage and 90% completeness gates. Exercise the additional synthetic fallback
cases and retain the final full-regression/build evidence.

Computer Use was retried after the user's earlier authorization but still
returned `Computer Use was not approved to use PoDoFo`. Native-window edge,
HiDPI, appearance, navigation, save, selection/narration and close checks remain
open. Automated widget/native-library checks do not establish that acceptance.
