# Target-aware previews: M3 on-demand layout

An internal-link hover can now refine an uncached target without first running
manual Analyze. Context appears after the existing debounce, then the resolver
receives a single target page's layout. Explicit FitR and unavailable source text
do not initialize analysis. Missing assets or failed initialization leave context
visible; automatic initialization retries only after an explicit analysis or
configuration action.

## Shared scheduling and models

`AnalysisCoordinator` owns at most one layout-only engine and borrows a warm
manual engine when available. It serializes preview inference, coalesces equal
page requests within the same document session/revision, and retains only the
latest pending page. Cancelling one subscriber detaches it; other subscribers
can still receive their shared result. A cancelled consumer resolves immediately,
while native work retains its ownership until it drains.

Manual Analyze/configuration reserves priority synchronously. It cancels and
drains preview work, closes the layout engine, then opens or uses the manual
engine. During manual analysis, previews read caches or subscribe to matching
layout updates. A miss does not queue inference behind the whole document.
The coordinator closes an owned engine and drains retained page images on close;
the controller continues to own its combined engine.

The application engine seam now exposes the SDK's `analyzePage` with explicit
formula scope. Hover requests `FormulaScope.none`. The Flutter loader's optional
`includeFormula: false` skips FormulaNet verification/opening; the default remains
the existing combined behavior. MathCAT is independent. `verifyLayout` supplies
verified layout identity and catalog metadata without opening a model or reading
formula/math payloads. This supports persisted cache reads after restart.

## Cache and provenance

Preview projections use `podoco/preview-layout-v1`, separate from manual
`podoco/pages-v2`, with a 16 MiB total and 4 MiB per-page disk budget. Shared
bounded/atomic storage checks document revision, page, render policy, and actual
pipeline key. Compatibility additionally checks backend, compute policy, layout
model identity, and the explicit layout-only or combined adapter/profile. The
combined case requires the matching formula manifest; it is not relabeled as a
layout-only pipeline.

The projection retains region geometry, reading order, and complete original
model/artifact/render provenance. It omits recognition outcomes, retaining the
required per-formula `not_requested` records. `layout_projection_scope` records
the original execution scope separately from the projection's scope. Projection
snapshots are layout-ready, not completed formula analyses, and reject formula
update merges. Manual layout/final-page updates publish through the same adapter;
individual formula updates continue to affect only the richer manual cache.

The worker's existing cancellation token now detaches repository subscriptions.
Disk/model waits remain outside PDF locks. The reader replaces its image/label
without selecting the target analysis page or changing viewport/history.

## Validation

Validated on 2026-10-30 with Flutter 3.47.5 / Dart 3.13.4. The app regression run
passed 101 tests; final focused reruns add the semantic reader interaction,
FitR/empty-source initialization guards, and warm-engine metadata retry, for
**104 distinct app tests**. The
Flutter loader passed **8 tests**. Both packages' static analysis passed.
The final macOS Debug application built and signed locally. Renderer integrity
still verifies all 53 pinned files, model/dependency pins are unchanged, and all
18 captured dirty-file hashes in the separate Podoco worktree still match.

Controlled scheduling tests cover coalescing, detached cancellation, latest-only
pending work, explicit priority, completion of manual subscribers, borrowed-engine
ownership, failure suppression/retry, and close during initialization. Storage
tests cover projection of a recognized formula without changing manual cache
bytes, exact provenance, incompatible profiles, corrupt files, pruning, and
per-page rejection. Reader tests verify the 350 ms debounce, semantic label,
repeat cache hit, unchanged visible analysis/viewport/history, and click behavior.

The opt-in native test uses actual bundled assets and the synthetic PDF. Cold
hover opens one layout manifest, stores only its target page, and opens no
combined engine. Manual Analyze drains/closes layout before combined opening.
A later hover preserves recognized equation cache bytes and visible analysis.
Restarted hover uses disk evidence without opening either engine. A gated native
image survives PDF close, is released exactly once during cancellation/drain,
and leaves zero Podoco native handles after coordinator disposal.

The final native run observed these durations, excluding the 350 ms hover delay:

| Operation | Duration |
| --- | ---: |
| Cold contextual raster | 22.6 ms |
| Layout engine opening (included in cold refinement) | 624.6 ms |
| Cold semantic refinement | 1,104.9 ms |
| Warm semantic refinement | 6.2 ms |
| Refinement after manual Analyze | 5.8 ms |
| First cache hit after restart, including layout verification | 265.0 ms |
| Combined engine opening for manual Analyze | 4,215.7 ms |

These are individual observations, not p50/p95 performance qualification. The
M5 benchmark and resource stress gates remain open. The raw measurements are
retained in `podofo_frontend_one/build/target-preview-m3/native-lifecycle.json`.

Commands use the pinned SDK and M1 corpus/model paths. Add
`test/analysis_coordinator_test.dart`, `test/preview_layout_store_test.dart`, and
`test/preview_analysis_native_test.dart` to the M2 regression command, with
`PODOCO_PREVIEW_NATIVE=1` and `--concurrency=1 --timeout=3m`. The native test uses
the generated offline pack under `.podoco/model_assets/models`. Run loader tests
and analysis in `podoco/bindings/flutter`. Logs are
`podofo_frontend_one/build/target-preview-m3-*.log`.

The native-window acceptance gate from M0 remains separate and pending. M4's
multipart targets/adaptive cards and M5's held-out quality/performance/native-UI
qualification are not claimed by these results.
