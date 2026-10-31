# Target aware link preview implementation plan

Use Podoco layout results, PDF text, and the actual link destination to preview
the complete referenced object. A citation should show its bibliography entry;
a figure or table should include its caption; an equation should include its
number. Ambiguous targets retain the existing contextual preview.

This implementation sequence is dated 2026-10-30. The first usable
release consumes existing analysis. Later milestones analyze uncached target
pages and improve difficult boundaries. M0 integration and automated validation
are implemented; its native-window acceptance check remains pending. See the
[M0 baseline report](target_aware_link_preview_m0.md). M1 resolution foundations
are implemented; see the [M1 report](target_aware_link_preview_m1.md). M2 cached
semantic previews are implemented; see the [M2 report](target_aware_link_preview_m2.md).
M3 on-demand layout analysis is implemented; see the [M3 report](target_aware_link_preview_m3.md).
M4 complete-target grouping, bounded multipart rendering and adaptive presentation
are implemented; see the [M4 report](target_aware_link_preview_m4.md). M5's held-out
accuracy and native-window qualification remains pending. M5 performance/stress
qualification is in progress; see the [M5 report](target_aware_link_preview_m5.md).

## Scope and behavior

The initial semantic path targets internal links in selectable-text academic
PDFs on macOS Apple Silicon, using the existing bundled Podoco layout profile.
Existing contextual previews remain available on other platforms and when
models, text, or convincing target evidence are unavailable.

Keep the current 350 ms hover delay, pointer pass-through, click and Back
behavior, and session/revision invalidation. Hover must not change selection,
navigation history, zoom, narration, or the document. Display a contextual crop
without waiting for model initialization; replace it at most once with a
confident complete target while that hover remains current.

The initial scope excludes unlinked citations, external-document resolution,
OCR, generated summaries, a Docling runtime dependency, model replacement, and
automatic full-document analysis. Formula transcription is unnecessary for a
visual equation preview. Existing analysis of an image-based page may still be
used when it provides sufficient target evidence.

## Integration baseline

| Component | Inspected committed baseline | Role |
| --- | --- | --- |
| Hover previews | `feat/internal-link-hover-previews`, `faeb1f4` | Overlay, destination geometry, bounded rendering and image cache |
| Podoco integration | `feat/podoco`, `c668cd3` | Layout inference, Dart results, bundled models, progressive analysis and persistence |
| Cloud file access | `feat/macos-cloud-file`, `95a5578` | Separate change following common ancestor `875e703` |

Podoco is not an ancestor of the cloud-file branch. Following the user's workspace
choice, integration uses `feat/internal-link-hover` in `podofo-hover-previews`.
The hover baseline and plan commit `c719e5a` were combined with committed Podoco
`c668cd3`. The viewer overlap retains hover dismissal and annotation-menu reset.

Keep the Podoco worktree's uncommitted FP32 and analysis-UI work separate. Its
unfinished qualification is not a prerequisite for this feature. Reuse the
committed model pins. Remote publication and model promotion are outside M0.

The current hover documentation records isolated-harness validation and an MLSR
dependency issue in that environment. Establish a fresh locked macOS application
baseline in the integrated worktree; do not inherit a full-build claim from
those harness tests.

## Architecture

PoDoFo owns target resolution because it owns PDF links, source text, navigation,
and preview presentation. Podoco continues to supply page regions and reading
order. Initially, the resolver is deterministic Dart logic over owned snapshots,
so it can be tested without loading Core ML.

```text
Hovered PDF link
  -> immutable request and source text
  -> normalized destination and target-page text
  -> cached Podoco layout or bounded single-page layout request
  -> candidate matching and related-region grouping
  -> resolved target or contextual fallback
  -> existing PDFium crop renderer and hover overlay
```

Proposed application contracts:

| Contract | Required contents |
| --- | --- |
| `LinkPreviewRequest` | Document/revision, source page and link rectangles, normalized destination, density, bounded source text/context |
| `PreviewLayoutEvidence` | Page dimensions, regions, native labels, reading order, analysis identity, and exact model/render provenance |
| `ResolvedLinkTarget` | Kind, supported label, ordered page rectangles, evidence identity, match tier, and diagnostic reason |
| `LinkTargetResolver` | Pure candidate selection and grouping; explicit unresolved result on ambiguity |
| `PreviewLayoutRepository` | Offscreen cache lookup and coalesced requests independent of visible-page selection |

Use match tiers such as `explicitArea`, `matchedIdentity`, and `unresolved`.
A detector score is evidence that a region has a particular class, not a
calibrated probability that the link refers to it. Keep detector confidence and
resolver acceptance separate.

### Coordinate and text rules

Use top-left, displayed-page PDF points throughout resolution. Reuse the hover
worker's conversion from raw destination coordinates, including the PDFium page
bounding-box origin. Podoco bounds already use the displayed orientation; do
not rotate them again. Convert pdfrx text rectangles into that same space and
test this separately from raw destination conversion.

Preserve which destination axes are known. A fabricated center coordinate must
not become semantic evidence. The pinned parser can lose PDF null parameters
through `GetView`; add a native null-versus-zero fixture and preserve XYZ
presence flags through PDFium's dedicated location API if necessary. For other
unresolved partial-coordinate cases, require corroborating text or fall back.
Respect explicit FitR bounds. Page-only destinations require a unique identity
match before selecting a specific object.

Extract text under the source link and limited neighboring text to distinguish
`Fig. 4`, `[23]`, `(7)`, and section references. Multiple numbers under a single
annotation are ambiguous unless destination evidence disambiguates them. Retain
source offsets and rectangles. Reuse the PDF text snapshot representation, not
the narration planner's stop-at-references or caption-skipping policies.

Use the destination to constrain candidates, then compare source labels, target
text, region type, column alignment, and reading order. Return unresolved when
competing candidates remain. Reference labels identify candidates; they do not
guarantee one region per bibliography entry.

### Cache and ownership rules

Read compatible manual-analysis snapshots through `AnalysisStore.read` without
calling `AnalysisController.select`. Add a bounded preview-layout namespace for
layout-only results, initially 16 MiB on disk and 4 MiB per page. It must never
write layout-only updates over existing equation-analysis snapshots. Project
manual layout updates into this namespace through a shared adapter.

Retain actual pipeline/model/render provenance in the projection. Do not assume
layout-only and combined formula profiles are interchangeable. Compatibility
must be explicit and tested. A preview projection carries layout readiness
separately from complete formula-analysis status.

Resolved-target and image keys include source-link identity, destination,
document revision, resolver version, layout evidence identity, selected bounds,
and render density where applicable. Two links sharing a page-level destination
must not share a semantic result merely because their destinations are equal.
Region IDs are local to an analysis, not permanent document object IDs.

Bound extracted text and geometry with an eight-page in-memory LRU and a 4 MiB
accounted payload limit. Reject pages exceeding 200,000 UTF-16 units for automatic
text matching, retaining contextual previews. Account text/coordinate payloads
explicitly; these limits are not a claim about total Dart heap usage.

Keep source extraction and rendering inside short session read-lock scopes.
Never await Podoco analysis while holding that lock: its page loader acquires
the same lock. Carry owned metadata between stages, then reacquire and validate
the revision before rendering. Preserve image clone/disposal ownership and late
result rejection across every new asynchronous boundary.

### Scheduling and model loading

The Dart SDK already exposes `Analyzer.analyzePage`; request
`FormulaScope.none`. No new native ABI is expected.

Add a shared application coordinator for the existing analysis controller and
preview repository. Maintain one active inference lane, one active preview
request, and at most the latest pending preview. Join identical page requests;
cancelling one consumer must not cancel work another consumer still needs.

An explicit document/equation analysis has priority. While it is running,
previews use cached results, subscribe to relevant layout updates, and otherwise
show context. Do not queue hover jobs behind the entire document or cancel that
document to satisfy hover. Explicit analysis may cancel and drain a preview job
before proceeding. PDFium/model cancellation remains cooperative.

The bundled loader currently opens FormulaNet whenever the pack contains it.
Add an explicit layout-only opening option while preserving the current default
for existing callers. A cold preview opens only layout. When explicit equation
analysis needs the combined engine, drain and close the layout engine before
opening the combined one. A warm combined engine can serve layout-only requests
without transcription. Close obsolete engines and suppress repeated automatic
initialization attempts after failure until an explicit retry or configuration
change. MathCAT and speech remain outside the preview path.

## Milestone 0 Establish the integrated baseline

Use the integration branch described above. Bring in the two committed feature
slices, retain dependency pins, and resolve overlap in `custom_pdf_viewer.dart`.
Keep the separate Podoco worktree's uncommitted work untouched.

Create a small native PDF fixture with real internal links and adjacent objects,
plus an evaluation manifest for real papers. Freeze document hashes, link source
rectangles, destinations, intended target kinds, required target parts, and
neighboring content that should be excluded.

**Done when:** the integrated application builds with locked dependencies;
existing hover, navigation, document-lease, analysis-store, bundled-loading,
and equation tests pass; a native macOS launch demonstrates both features.
Record any baseline failure before implementing semantic changes.

## Milestone 1 Add target contracts and offscreen evidence access

Add request/result types, the coordinate adapter, source-link text extraction,
and a read-only offscreen layout lookup. Preserve current rendering as the
fallback. Introduce semantic cache keys and the short-lock stage boundaries.
Resolve explicit FitR targets without model inference; leave ambiguous point
destinations contextual at this stage.

Suggested files under `podofo_frontend_one/lib/src/`:

- `previews/link_target.dart` and `previews/pdf_link_context.dart` for contracts,
  source identity, text, and coordinate conversion.
- `previews/link_target_resolver.dart` for pure resolution.
- `analysis/preview_layout_repository.dart` for offscreen evidence access.
- Existing `workers/link_preview_worker.dart` for staged requests and rendering.

**Done when:** an offscreen cache read leaves the visible page, equation
selection, and navigation unchanged; null coordinates, all rotations, CropBox
offsets, repeated destinations, revision changes, and failed reads have defined
fixture outcomes; existing previews work without Podoco results.

Depends on milestone 0.

## Milestone 2 Ship useful previews from cached analysis

Implement four initial resolvers over existing layout and PDF text:

| Kind | Initial acceptance rule |
| --- | --- |
| Citation | Match number or author/year near the destination; include consecutive lines belonging to that entry; stop at the next entry or reject an uncertain boundary |
| Figure or table | Match caption identity and destination neighborhood; associate the visual using column/geometry/order evidence; include visual and caption |
| Equation | Match number and nearby formula; union related regions without requiring LaTeX recognition |
| Section | Match heading; include the opening text block rather than the entire section |

Use native subtypes such as `reference_content`, `figure_title`, and
`formula_number` instead of only broad categories. Detect conflicting or
overlapping candidates and abstain when identity or completeness is uncertain.
Initially accept only complete single-page targets. A known continuation beyond
that page retains context until milestone 4.

Render original PDF pixels with modest bounded padding. Show a semantic label
only when supported, such as `Figure 4 · Page 7`; otherwise keep the page label.
Maintain the existing 360 by 240 logical-pixel envelope for this first release.

**Done when:** analyzed papers show complete, correctly identified examples of
all four kinds; adjacent references and nearby figures do not leak into the
selected target; unresolved cases stay contextual; synthetic fixtures assert
both included target pixels and excluded neighboring pixels. Capture paired
baseline/semantic crops for the initial real-paper set.

Depends on milestone 1. This is the first independently usable feature release.

## Milestone 3 Analyze uncached target pages on demand

Implement the shared coordinator, preview-layout persistence, and selective
bundled loading described above. Extend the application `AnalysisEngine` seam
to expose the SDK's existing single-page operation and requested formula scope.
Retain the manual Analyze flow and its richer cache.

Begin work only for a settled internal-link hover after the existing debounce.
On a miss, keep the contextual preview visible while the bounded target-page
request runs. Re-resolve on layout readiness, not formula completion. Cancel or
detach obsolete consumers on hover exit, document changes, and disposal.

Primary changes include `analysis_engine.dart`, `analysis_controller.dart`, a
new shared coordinator/provider, the preview repository, and
`podoco/bindings/flutter/lib/src/model_loader.dart`.

**Done when:** a cold hover analyzes only its requested target page and opens no
formula or math model; a warm hover reuses results; rapid hover leaves bounded
work; explicit analysis retains priority; layout-only work never removes a
recognized equation result; cancellation and close drain native leases safely.
Measure cold initialization separately from warm analysis and cache-hit latency.

Depends on milestone 2.

## Milestone 4 Complete difficult targets and fit their presentation

Extend reference segmentation for hanging indents, author/year entries, numbered
lists, column transitions, and continuations across an adjacent page. Extend
figure grouping for multiple panels and captions above/below the visual. Handle
multiline equations and independently detected numbers.

Represent a target as ordered rectangles rather than one large union that might
include an unrelated column. Bound expansion to four rectangles over at most
two adjacent pages; analyze the second page only when continuation evidence
justifies it. Larger or uncertain targets retain contextual previews.

Adapt the card to target aspect ratio, up to 480 by 360 logical pixels and the
available viewport. Keep DPR capped at 2, preserve aspect ratio, and bound the
sum of crop rasters and the final composite. A maximum final raster is 960 by
720 pixels, or 2,764,800 BGRA bytes. Retain the existing 6 MiB decoded-image LRU;
larger previews naturally retain fewer entries. Limit transient raster payloads
to one composite plus one source crop, with explicit accounting. These budgets
exclude model weights, PDFium internals, and framework allocations.

Use original pixels in all slices. Preserve visible continuation context and
reading order. Fit the complete target rather than silently cutting off content
to fill the card. If completion cannot be established, use the contextual view.

**Done when:** paired visual review covers multipart figures, long references,
cross-column and cross-page entries, rotated pages, and narrow overlays; accepted
previews retain required components; image bounds and cleanup remain verified
at every supported density.

Depends on milestone 3. Core grouping work can be developed after milestone 2,
but automatic second-page analysis requires milestone 3.

## Milestone 5 Qualify target accuracy and reader behavior

Use a bounded initial corpus of approximately 100 annotated links across at
least 12 papers, with separate documents for development and held-out review.
Reserve at least 10 held-out examples each for citations, figures/tables,
equations, and sections. Include author/year and numbered references, multiple
columns, repeated destination coordinates, offset/rotated pages, and ambiguous
links. Add synthetic failure cases for unsupported platforms, missing assets,
malformed destinations, and textless pages.

Annotate eligibility before examining resolver output and report fallback rates
for every sampled link, including ineligible ones. Freeze resolver rules before
the held-out run. Retain per-link metadata, baseline
crop, semantic crop, selected regions, acceptance/fallback reason, and timing.
If a held-out example drives a rule change, move it to development and replenish
the held-out set. PDF licenses determine whether source fixtures can be checked
in; keep hashes and manifests for local-only documents.

Initial release gates are engineering targets, not established accuracy claims:

- No wrong-object semantic previews on the held-out set; ambiguous examples
  must fall back.
- Resolve at least 8 of 10 eligible held-out links in each target group, so
  universal fallback cannot pass the identity gate.
- At least 90 percent of resolved previews contain all annotated required
  parts and exclude annotated unrelated neighbors; report counts by type and
  inspect every failure. Known clipped-target regressions become blocking tests.
- Preserve navigation, pointer pass-through, dismissal, selection, narration,
  revision invalidation, and model/renderer cleanup under native UI testing.

Measure p50/p95 end-to-end times for memory hits, disk hits, warm single-page
analysis, and cold preparation separately. An initial usability target is a
cached semantic image at p95 within 150 ms after the hover debounce; measure on the
named host and retain the contextual image if a slow path exceeds that budget.
Report warm-analysis latency before setting an inference deadline. Repeat a
bounded 100-request hover/cancel cycle and verify caches remain within limits
and native handles return to their warm baseline, then zero after disposal.

Run focused Flutter resolver/cache/worker/widget tests, native crop tests,
existing reader and Podoco regressions, analysis/format checks, and a signed
macOS build. Run loader Dart tests for selective model loading. Rust/C tests are
required if implementation changes those layers; the initial path does not
require a native ABI change. Perform actual macOS UI checks for viewport edges,
high DPI, light/dark appearance, click/Back, tab changes, save, and close during
inference. Update feature and validation documentation with measured boundaries
and unsupported cases.

**Done when:** retained evidence meets the gates, the packaged app passes the
reader checks, and remaining fallback cases are documented. Reassess the model
or grouping strategy if coverage fails; do not hide the gap by weakening identity
checks. Docling can serve as a later comparison for failing cases without
becoming a runtime dependency for this implementation.

Depends on milestone 4. Evaluation fixtures and capture tools begin in milestone
0 and grow with each feature milestone.

## Delivery and effort

Deliver each milestone as a reviewable change with its own validation record.
Milestone 2 provides useful previews on already-analyzed documents; milestone
3 removes that prerequisite; milestones 4 and 5 complete and qualify the broader
behavior. The sequence is `0 -> 1 -> 2 -> 3 -> 4 -> 5`.

Rough focused engineering effort is one day for integration/baseline work,
one to two days for contracts and cache access, two to three days for the first
resolvers, two to three days for selective loading and scheduling, and another
three to six days for difficult targets and qualification. These are planning
ranges, not measured delivery times. Re-estimate after the first real-paper
crop review; model misses and inconsistent bibliography boundaries are the
largest accuracy risks.

## Source pointers

The hover baseline is documented in [link_hover_previews.md](link_hover_previews.md).
The following paths refer to the inspected `feat/podoco` baseline and become
available in the integrated worktree:

- `podoco/crates/podoco/src/results.rs`: region and page result contracts.
- `podoco/model-manifests/pp-doclayout-v3-coreml-v1.yaml`: preserved native labels.
- `podoco/bindings/dart/lib/src/analysis_jobs.dart`: existing `analyzePage` API.
- `podoco/crates/podoco/src/jobs/engine.rs`: serial inference lane.
- `podoco/bindings/flutter/lib/src/model_loader.dart`: current bundle opening.
- `podofo_frontend_one/lib/src/analysis/pdf_analysis_source.dart`: canonical
  coordinates, raster policy, and session locking.
- `podofo_frontend_one/lib/src/analysis/analysis_store.dart`: per-page cache and
  update ownership.
- `podofo_frontend_one/lib/src/analysis/analysis_controller.dart`: visible-page
  state and whole-document orchestration.
- `docs/document-analysis.md` and `podoco/docs/internal/m6-document-validation.md`:
  existing integration and quality boundaries.
