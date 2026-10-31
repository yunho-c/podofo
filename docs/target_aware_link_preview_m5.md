# Target-aware previews: M5 qualification in progress

M5 is not complete. The fifth frozen held-out run fails citation coverage and
completeness, including a reference missing its final year/backlink line. Papers
driving changes move to development before those changes; all five evaluations
are preserved. Native-window acceptance also remains unqualified.

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

The latest performance run is `performance-v5` at resolver version 13, on an Apple M4 Pro with
48 GiB RAM, macOS 27.0.1 (26A434), Flutter 3.47.5 / Dart 3.13.4, using the bundled
experimental mixed layout profile and the existing linked-object Figure 4 at 2x.
These are fixture observations, not a corpus-wide or release-mode benchmark.

| Path | Samples | Semantic p50 | Semantic p95 | Context p95 |
| --- | ---: | ---: | ---: | ---: |
| Decoded image and text reuse | 30 | 1.7 ms | 2.4 ms | 0.29 ms |
| Persisted layout, fresh worker/coordinator | 20 | 8.3 ms | 11.1 ms | 1.8 ms |
| Warm model, forced layout miss | 20 | 69.6 ms | 76.3 ms | 2.1 ms |
| Cold app preparation | 20 | 645.7 ms | 904.0 ms | 3.2 ms |

Timing begins at `LinkPreviewWorker.load` and ends at the contextual future or
semantic callback; it excludes the 350 ms hover debounce, captures and assertions.
Cold means a fresh worker, coordinator and empty layout directory with the PDF
already open. The process, OS page cache and Core ML compilation cache remain
warm. Decoded-image/text reuse still reads layout provenance from disk; it is
not a disk-free path. New inference is counted explicitly, so a purported warm
analysis sample cannot pass by accidentally reusing persisted layout.

The initial failing run remains under `build/target-preview-m5/performance-v1/`;
`performance-v2` through `performance-v5` retain subsequent raw samples. Both
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
resolver output was examined. The initial six held-out papers received
independently reviewed source annotations before any resolver/model output.

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

## Nested heading correction and replenishment

Resolver version 8 includes an explicit descendant heading between the linked
section heading and its opening paragraph. Numeric hierarchy (`5` then `5.1`) and
Roman-section/alphabetic-subsection hierarchy (`II` then `A`) are preserved.
A sibling or unrecognized intervening heading prevents resolution, so the
resolver cannot borrow the next section's paragraph while omitting its heading.
Both new geometry regressions failed before this change and pass afterward.

The expanded development replay covers 79 links in nine documents: 72 eligible
targets and seven controls. `papers-nested-headings-development-v2` resolves 17/18
citations, 17/18 figures/tables, 17/18 equations and 15/18 sections. All 66 accepted
targets pass completeness/neighbor checks; all controls fall back and native
handles return to zero. Both corrected real-paper crops were visually reviewed.
The focused run passed 48 tests. The three compound section labels remain
development fallbacks and have not been reclassified as ineligible.

The full Flutter suite passed 393 tests with 21 opt-in skips. The final native
replay also passed the original fourteen-target evaluation and verified all 37
current annotation/pipeline identities. Static analysis, formatting and the
53-file pinned-engine check pass. Logs use `build/target-preview-m5-nested-headings-`;
original-target captures are under
`build/target-preview-evaluation/m5-nested-headings-regression/`. All eighteen
recorded unrelated Podoco worktree files remain unchanged.

The macOS Debug build and deep/strict local signature verification passed
(`build/target-preview-m5-nested-headings-build.log`). Building/signing ran after
native tests completed; native-window acceptance is still outstanding.

Replacement papers are selected before their source review or resolver output:
`1810.01497v2`, `2206.07867v3`, and `2410.06940v4`. Selection takes the first three
previously unused arXiv-named PDFs in filename order, limited to 60 pages and at
least two named destinations in each target group. It examined link metadata in
17 candidates, without running the detector or resolver. The selection record is
`test/fixtures/target_preview/m5_history/replenishment_v2_selection.json`.
Independent preparation produced 27 new links and source-page images under
`build/target-preview-m5/annotations-v3-replacements/`. Their eligibility and
boundaries still need visual review; there is no replacement held-out result yet.

## Compound sections and same-page column continuation

Resolver version 9 preserves IEEE-style compound identities such as `II-C`.
When the printed heading contains only the child label, it checks the closest
preceding Roman heading in detector reading order. A contradictory parent is
rejected. If the parent is on an earlier page, the actual PDF destination must
fall within 32 points of the uniquely matching child heading; a page-only link
cannot establish that context. Multiple selected labels and non-section prefixes
still fall back.

An unfinished opening paragraph now checks the next body column before requesting
another page. The same completion, typography, heading-boundary and crop checks
apply to both paths. Figures/tables do not supply prose continuations. A new
heading, reversed reading order or an unfinished continuation remains unresolved;
the resolver does not skip that column to search a later page.

The 79-link `papers-compound-sections-development-v1` replay resolves all 18
sections completely. Citations, figures/tables and equations each remain 17/18;
all 69 accepted targets pass required/excluded ink checks, all seven controls fall
back and native handles return to zero. The focused suite passed 50 tests. The
compound-label and cross-column regressions both failed before the fix. The
corrected two-column opening and long subsection crop were visually reviewed.
This remains development evidence; replacement held-out annotations and the next
frozen qualification run are still required.

The full Flutter suite passed 395 tests with 21 opt-in skips. Static analysis,
formatting and the pinned-engine check pass. The final native run also passed
the original fourteen-target evaluation. Logs use
`build/target-preview-m5-compound-sections-` and original-target captures are in
`build/target-preview-evaluation/m5-compound-sections-regression/`.

The macOS Debug app also builds and passes deep, strict verification of its local
signature. The build log is
`build/target-preview-m5-compound-sections-build.log`. Native-window acceptance
remains pending.

Before changing figure rules, `2511.23342v3` was also promoted from the original
held-out run: its individually linked `Fig. 2a` points to the whole Figure 2 and
currently falls back. Its eligibility and boundaries are unchanged. The promotion
is recorded in `m5_history/panel_reference_promotion.json`. This expands development
to 87 links in ten papers; `papers-compound-sections-development-v2` resolves 19/20
citations, 18/20 figures/tables, 19/20 equations and 20/20 sections, with all 76
accepted targets complete and native handles returning to zero.

The next metadata-only selection chose `2504.17670v2` as its replacement, excluding
all versions of previously sampled paper IDs. Its eight source-only cases and page
renderings are under `build/target-preview-m5/annotations-v4-panel-replacement/`;
source annotations are pending. See `m5_history/replenishment_v3_selection.json`.

## Panel-qualified figure identities

Resolver version 10 accepts a numeric panel identity such as `Figure 2a` against
the caption `Figure 2` only when that grouped figure explicitly identifies panel
`a` in its own caption or panel labels. It retains the complete parent figure and
shared caption. An absent panel, a label outside the group, and table suffixes do
not establish this match. Exact independently numbered captions still work.

Panel labels classified as `vision_footnote` text now join their figure when they
begin with a letter marker and lie inside its group envelope. Ordinary prose
remains a grouping boundary. This resolves the promoted `2511.23342v3` case without
changing its original eligibility or required/excluded bounds. Paired source-page
and semantic-crop review confirms both panels, both labels and the full caption.

Both new regression tests fail on version 9 and pass on version 10. The focused
suite passes 51 tests; the full Flutter suite passes 397 with 21 opt-in skips.
Static analysis and formatting pass. The final native replay
`papers-panel-development-v2` covers 87 links across ten development papers:
19/20 citations, 19/20 figures/tables, 19/20 equations and 20/20 sections resolve.
All 77 accepted targets pass required/excluded ink checks; all seven unsupported
controls fall back and native handles return to zero. The original fourteen-target
native evaluation also passes under `m5-panel-final-regression`. Logs use the
`build/target-preview-m5-panel-` prefix. These remain development results; the
replacement held-out set has not been evaluated.

The macOS Debug app builds and passes deep, strict verification of its local
signature (`build/target-preview-m5-panel-build.log`). The pinned-engine verifier
passes all 53 files. Native-window acceptance remains pending.

## Replenished held-out freeze

Four replacement papers now have source annotations completed before their first
resolver/model output: `1810.01497v2`, `2206.07867v3`, `2410.06940v4` and
`2504.17670v2`. Their 35 sampled links comprise 32 eligible targets and three
unsupported footnotes. Review used complete source/target page renderings and
independent MuPDF text geometry. The annotations include complete cross-column
section openings, every panel and shared figure caption, and interleaved display
equations where the opening section paragraph continues through them. Source PDF
hashes, page bounds, nonempty required/excluded ink and disjoint annotations pass
independent checks.

Together with the unchanged `1809.02736v1` and `2606.29940v2` carryovers, this gives
50 held-out links: 12 eligible citations, 12 figures/tables, 11 equations and 11
sections, plus four unsupported controls. The two carryover documents were seen in
the first evaluation and did not drive rule changes; the 35 replacement links are
new. The current sample totals 137 links across sixteen papers, in addition to the
eight earlier real-paper development links across two seeds.

The second freeze records resolver version 10 at `412a2c4` and hashes all six
annotations plus the 28 pipeline, model, sampling and evaluation inputs. This
freeze is committed before the second held-out run. The first freeze, sample and
failed results remain preserved in `m5_history/`.

## Interrupted second held-out run

`held-out-v2` captured all fifteen carryover links, then stopped before resolving
any target in `1810.01497v2`. Its page-one external arXiv link (xref 8) has raw
rectangle `[37.62, 250, 10.94, 603.96]`. The vendored PDF link loader normalizes
vertical coordinates but passes the reversed horizontal pair to `PdfRect`, which
asserts. The failure is unrelated to the sampled citation itself. Native analysis
handles return to zero, but the run is incomplete and establishes no new accuracy
result. See `build/target-preview-m5-held-out-v2.log` and its retained captures.

The complete freeze, sample and compact partial results are archived as
`m5_history/held_out_v2_*.json`. The active freeze is removed. The whole
`1810.01497v2` document moves to development before changing the link loader; its
eligibility and required/excluded bounds remain unchanged. It needs a new held-out
replacement. The other three replacement papers still have no resolver/model
output. The loader fix must be covered by a synthetic reversed-rectangle test,
and the next freeze must also identify the reviewed vendored engine pin.

## Native link rectangle recovery

The vendored `pdfrx_engine` now normalizes both rectangle axes before creating a
link. Failed reads, nonfinite coordinates and zero-area rectangles are skipped;
PDFium reports an absent `/Rect` as a successful zero rectangle in the synthetic
fixture. Each opened annotation closes in a `finally` block. The change remains
in Dart's PDFium binding layer with the same engine/PDFium versions and native ABI.
The synthetic native test failed with the original assertion before the fix and
now covers reversed horizontal/vertical/both axes, missing geometry, preserved
internal destinations and a valid external URL.

The complete source patch was regenerated from all 52 hash-verified upstream
files. Applying it in an isolated directory reproduces all 53 pinned vendored
files byte for byte, including line endings. The evaluation identity now includes
the engine pin and native Dart implementation, increasing pipeline identities
from 28 to 30 for the next freeze.

The full Flutter suite passes 398 tests with 21 opt-in skips; analysis and format
checks pass. The real lease/import/cancellation/sink tests pass with the layout
bundle (eight combined tests, with two separate corpus opt-ins skipped). The final
native run also exercises the fourteen original targets and the M4 complex-target
corpus. Its development replay, `papers-link-rect-development-v2`, covers 96 links
across eleven papers: 21/22 citations, 21/22 figures/tables, 21/22 equations and
22/22 sections resolve completely. All 85 accepted targets pass required/excluded
ink checks, all eight controls fall back and native handles return to zero. All
eight accepted crops from the promoted paper were visually reviewed against the
original pages. Logs use `build/target-preview-m5-link-rect-`.

The macOS Debug build passes local deep/strict signature verification. Native
window access was retried after the earlier user authorization and is still denied
by Computer Use, so that acceptance remains open.

The same metadata-only replenishment policy selected `2509.22935v2`, recorded in
`m5_history/replenishment_v4_selection.json`. Its source-only preparation contains
nine links under `build/target-preview-m5/annotations-v5-loader-replacement/`.
Independent visual review includes its cross-page reference and section opening.
Its eight eligible targets and one unsupported control are now annotated, with
source hash, page bounds, nonempty ink and disjoint required/excluded bounds
verified. The current sample contains 146 links across seventeen papers, plus
the eight earlier links in two development seeds.

The third freeze uses baseline `57d9503`, resolver version 10 and all 36 annotation
and pipeline identities, including the native link loader. It still has fifty
held-out links across six documents: 12 citations, 12 figures/tables, 11 equations,
11 sections and four controls. Thirty-five links are new to target resolution;
fifteen are unchanged carryovers. The annotated replacement and freeze are
committed before the next full held-out run.

## Third held-out evaluation: figure coverage and reference boundary failure

The full `held-out-v3` run at `75b1d04` captured all fifty links with all 36 frozen
identities intact and native handles returning to zero. It resolves 11/12 citations
(10/11 complete), 9/12 figures/tables (all nine complete), 10/11 equations (all ten
complete) and 9/11 sections (all nine complete). All four controls fall back.
Figure/table coverage is 75%, below the 80% gate. Although citation completeness
is just above 90%, its known neighboring-entry regression is blocking.

The accepted Xu (2024) reference in `2509.22935v2` contains the entire following
Zhang bibliography entry. Source-page and semantic-crop review confirm the failure;
the annotated target is complete, but all 8,256 excluded neighboring ink pixels
are also included. This requires a bibliography-boundary regression test. The
same document's cross-page Frantar reference and equation-interleaved section
opening fall back. Other fallbacks include both figures in `2206.07867v3`, the
partially selected `2(` in the `Figure 2(a)` link of `2504.17670v2`, its
equation-interleaved section opening, and the unchanged `.3)` equation source in
`2606.29940v2`.

The first two figure failures and partial panel source drive further figure
development; `2206.07867v3`, `2504.17670v2` and `2509.22935v2` move as whole
documents to development before changes. Their eligibility and required/excluded
bounds are unchanged. Archive files `m5_history/held_out_v3_*.json` preserve the
freeze, sample, per-link results and separate new/carryover summaries. Paired
captures remain under `build/target-preview-m5/papers-held-out-v3/`, with the log at
`build/target-preview-m5-held-out-v3.log`. The automatic wrong-object flags are zero;
this is not a completed manual audit of all 39 accepted crops. The active freeze
is removed and the three promoted documents must be replenished.

## Bibliography boundary correction

Resolver version 11 recognizes full first-author names followed by `and`, and
names containing a spaced middle initial, when separating bibliography entries.
The existing left-margin check still prevents an indented editor/author line
inside a reference from starting a new entry. Synthetic tests cover separate and
merged layout regions, retain URL continuation lines and exclude the next entry.
The full-name boundary test failed before the correction and now passes.

The focused resolver/native-fixture run passes all 53 tests. The development
replay `papers-reference-boundary-development-v1` captures all 122 links from
fourteen documents: 26/28 citations, 24/28 figures/tables, 27/28 equations and
26/28 sections resolve completely; all ten controls fall back. All 103 accepted
targets pass required/excluded ink checks and native handles return to zero.
The corrected Xu (2024) crop was visually checked against the original page:
all 2,890 required ink pixels remain and zero of the 8,256 excluded neighboring
pixels remain. The prior failed held-out captures and annotations are unchanged.
The cross-page reference with its year on the following page still falls back.
This development replay does not replace the pending held-out qualification.

## Figure panel syntax and caption-backed headings

Resolver version 12 retains panel identity for a parenthesized figure reference,
including an annotation that selects `2(` while the immediately following text
supplies `a)`. It requires an explicit figure prefix and a single complete panel
suffix. Missing or ambiguous suffixes, multiple selected panels, an equation
prefix, and a panel absent from the target figure still fall back.

The parent caption can identify a panel with either `(a)` or `a)`. A short panel
heading classified as text or heading joins the figure only when the main
caption identifies the same panel and the heading lies immediately above an
aligned visual. This retains the three panel titles in the promoted information
theory figure. The existing whole-parent-figure rule and neighboring-region
guards remain in force. Both new regression tests failed before the changes.

The development replay `papers-panel-syntax-development-v1` resolves 26/28
citations, 26/28 figures/tables, 27/28 equations and 26/28 sections. All 105
accepted targets pass required/excluded ink checks, all ten controls fall back,
all 44 input identities match, and native handles return to zero. Both newly
resolved figure crops were visually checked against their full original pages;
all panels, labels and captions remain, without neighboring text. The full
Flutter suite passes 402 tests with 21 opt-in skips; full analysis, formatting and
the exact 53-file vendored-engine pin verification pass. The 18 unrelated dirty
files in the separate Podoco worktree remain byte-identical.

The signed macOS Debug build passes deep/strict signature verification. A final
explicit native run passes all four tests: the original fourteen-target corpus,
M4 complex targets, the cache/model timing and 100-cycle cancellation stress run,
and the bundled-payload identity guard. Cached semantic p95 remains below the
150 ms gate, and owned caches and native handles drain after disposal. That run's
raw samples are under `performance-v4/` (the
original doubled run-prefix directory was renamed after completion). Validation
logs use `build/target-preview-m5-panel-syntax-`.

The second figure in `2206.07867v3` still falls back: the detected image boundary
overlaps a separate displayed formula from preceding prose. Trimming that
boundary without evidence of visual ownership could discard real figure content,
so this remains an explicit unsupported boundary case. The cross-page reference
whose year appears only on the following page and equation-interleaved section
openings also remain fallbacks. No eligibility or target annotations changed.

## Fourth source-reviewed freeze

The unchanged metadata-only replacement policy selected `2512.05016v2`,
`2512.05117v3` and `2603.26571v4`. The selection excludes every version of all
previously sampled papers, including the two development seeds; its record is
`m5_history/replenishment_v5_selection.json`. The 25 new links were independently
reviewed against full source/target pages and MuPDF text geometry, with no
resolver/model output. All source hashes, page bounds, nonempty ink and disjoint
required/excluded regions validate. Review includes two cross-page section
openings and a composite figure containing a table, plot, explanatory note and
shared caption. The footnote remains an unsupported control.

The fourth freeze fixes resolver version 12 at baseline `8c1afbe` and all 36
pipeline/annotation identities. It contains 49 links across six held-out papers:
12 citations, 12 figures/tables, 11 equations, 11 sections and three controls.
Twenty-five links are newly reviewed; 24 unchanged links in three papers are
carryovers that did not drive rule changes. The full sample now contains 171 links
over twenty papers, plus eight links in the two earlier development seeds. The
source annotations and freeze are committed before the next held-out run.

## Fourth held-out evaluation: equation margin regression

The full `held-out-v4` evaluation at `978d74c` captured all 49 links with all 36
frozen identities intact and native handles returning to zero. It resolves 10/12
citations, 10/12 figures/tables and 10/11 sections completely. Equations resolve
10/11, with nine complete. All three controls fall back. Every group meets the
aggregate coverage/completeness thresholds, but the accepted Equation (1) in
`2512.05117v3` clips part of its radical overbar: it retains 1,091 of 1,134 required
ink pixels and no excluded neighboring ink. The native crop and an independent
source render confirm this blocking defect. A loose preceding-prose model box
suppresses the crop margin needed for the vector stroke above the formula glyphs.

The whole paper moves to development before changing boundary handling. Its
eligibility and required/excluded annotations stay unchanged. This also retains
its composite-figure and cross-page-section fallbacks as development evidence.
All freeze/sample/results metadata are archived as `m5_history/held_out_v4_*.json`;
paired captures remain under `build/target-preview-m5/papers-held-out-v4/` and the
log is `build/target-preview-m5-held-out-v4.log`. All forty accepted previews have
zero automatic wrong-object flags; this is not a completed visual audit of them.
The active freeze is removed and one replacement paper is required.

## Native text-line boundaries preserve equation margins

Resolver version 13 constrains padding against native text-line bounds for prose
regions with selectable text. A loose paragraph model rectangle no longer treats
whitespace after a ragged last line as ink, allowing the equation's three-point
margin to retain a radical overbar outside PDF glyph bounds. Each text line keeps
a safety margin; textless regions, graphics and separate formula regions still
constrain padding using model bounds. The selected target content is never
reduced, and the existing foreign-region checks remain in place.

The new synthetic regression fails before this change and passes afterwards;
it also verifies genuine neighboring text and textless-region boundaries. All
56 focused tests and 403 full-suite tests pass, with 21 opt-in skips in the latter.
Full analysis, formatting and the 53-file engine-pin verification pass. The native
development replay `papers-equation-margin-development-v1` covers 130 links across
fifteen papers: 28/30 citations, 27/30 figures/tables, 29/30 equations and 27/30
sections resolve completely. All 111 accepted crops pass required/excluded ink
checks, all ten controls fall back, all 45 input identities match, and native
handles drain to zero. The original fourteen-target and M4 complex native corpora
also pass. The corrected radical was visually compared with an independent
source render: all 1,134 required pixels remain and none of the 5,244 excluded
pixels are included. Logs use `build/target-preview-m5-equation-margin-`.

The macOS Debug build and deep/strict local signature verification pass. The
current `performance-v5` run and bundled-payload guard pass, retaining all 90
timing samples and 100 hover/cancel cycles. Cached semantic p95 is 2.4 ms for
decoded reuse and 11.1 ms for persisted layout. Warm-analysis p95 is 76.3 ms and
cold-preparation p95 is 904.0 ms; these are separate observed paths with the
timing boundaries above. Owned-cache peaks are unchanged and all handles drain
after disposal. The reusable loader's tests pass separately with `--no-pub`,
including unsupported-platform and missing/changed-asset rejection. Unrelated
Podoco changes remain preserved.

## Fifth source-reviewed freeze

The same source-only selection policy chose `2605.10938v2` to replace the promoted
equation paper. Its nine links were visually reviewed before resolver/model
output, including the page-bottom numbered reference and the complete three-panel
system-comparison figure. Source hash, nonempty ink, page bounds and disjoint
required/excluded regions validate. The sampling record is
`m5_history/replenishment_v6_selection.json`; local source renders and independent
text geometry are under `build/target-preview-m5/annotations-v7-replacement/`.

The fifth freeze fixes resolver version 13 at `024def7` and all 36 inputs. The
six-paper held-out set contains 50 links: 12 citations, 12 figures/tables, 11
equations, 11 sections and four controls. Nine links are new and 41 are unchanged
carryovers that did not drive rule changes. The complete sample now has 180 links
over twenty-one papers, plus eight links in the two earlier development seeds.
The annotation and freeze are committed before evaluating the set.

## Fifth held-out evaluation: citation boundary and source regressions

The full `held-out-v5` run at `dcc8226` captured all 50 links, with all 36 frozen
identities matching and native handles returning to zero. Citations resolve
9/12, with eight complete: both the 80% coverage and 90% completeness gates fail.
Figures/tables resolve 11/12, equations 10/11 and sections 11/11, all complete;
all four controls fall back. These are automatic checks, not a completed visual
audit of every accepted crop.

The accepted reference [73] in `2605.10938v2` retains 3,685 of 3,896 required ink
pixels and no excluded neighboring ink. Visual review confirms that its final
line, containing the publication year and backlinks, is absent. The indented
`2021.` is mistaken for a numbered entry. Its page-bottom reference [72] also
falls back despite a separate entry on the next page. In `2603.26571v4`, author
links followed by bracketed years and a figure link selecting the abbreviation's
period fall back at source identification.

Both whole papers move to development before any rule changes. Eligibility and
required/excluded annotations are unchanged. Freeze, sampling and results are
archived as `m5_history/held_out_v5_*.json`; full paired captures remain under
`build/target-preview-m5/papers-held-out-v5/`. The active freeze is removed;
two source-reviewed replacements are required before another held-out run.

## Remaining acceptance work

Fix the promoted citation/source regressions, then replenish and freeze before
evaluating every held-out link with paired images,
required/excluded pixel metrics and per-group
coverage. Inspect all failures against the original zero-wrong-object, 8-of-10
coverage and 90% completeness gates. Exercise the additional synthetic fallback
cases and retain the final full-regression/build evidence.

Computer Use was retried after the user's earlier authorization but still
returned `Computer Use was not approved to use PoDoFo`. Native-window edge,
HiDPI, appearance, navigation, save, selection/narration and close checks remain
open. Automated widget/native-library checks do not establish that acceptance.
