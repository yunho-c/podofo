# Experimental document and equation analysis

PoDoFo uses the public Podoco Dart SDK for PP-DocLayoutV3 layout detection and
PP-FormulaNet_plus-L formula recognition on macOS Apple Silicon. Successful
formulas become available progressively for Copy LaTeX and optional MathCAT-to-MLSR
listening. This remains a Developer-mode feature: native parity is qualified,
while detector/recognizer quality and human listening acceptance remain separate
promotion gates. See the [measured corpus limits](../podoco/docs/internal/m6-document-validation.md).

## Build and use

Prepare the existing [MLSR dependency](tts-implementation.md#build-preparation),
then run from `podofo_frontend_one/` with the pinned Flutter 3.47.5 toolchain:

```sh
python3.13 tool/prepare_podoco.py
flutter pub get --enforce-lockfile
bash tool/build_macos_local.sh release
```

The new helper builds this checkout's Rust SDK into ignored `.podoco/native/`.
It enables Core ML on macOS arm64 and optional math conversion on all supported
desktop hosts. It does not fetch models. The local build helper keeps
the application at the host architecture and signs it locally; no global Flutter
configuration change is needed. Re-run native preparation after Rust SDK changes.

Prepare the explicit [M2 local layout bundle](../podoco/tools/pp_doclayout_v3/README.md).
In the reader's **Debug** pane, enable **Developer mode**, choose **Open layout
model…**, and select the directory containing `podoco-bundle.yaml`. This opens
and verifies local files for the current application session. Then choose
**Analyze document layout**. The pane shows page progress, the final outcome,
and whether the visible page is complete or partial. **Cancel analysis** drains
work already in flight. **Show layout regions** toggles blue region outlines;
formula outlines use orange.

To recognize equations, also prepare the [formula bundle](../podoco/docs/formula.md)
and choose **Open formula model…** before **Analyze document and equations**.
Select a pending or completed equation in the current-page list. A successful
result enables **Copy LaTeX**, which copies the original recognition verbatim.
Incomplete and failed results stay visible but do not enable Copy or Listen.

For speech, prepare the [optional math rules](../podoco/docs/math.md), choose
**Open math speech rules…**, then choose a supported style and **Listen to equation**.
The audio settings provide the language, voice, and speed; the existing audio
player provides pause/resume and Stop. A language without an exact installed
MathCAT entry is unavailable; there is no silent regional-language fallback.
Conversion failures keep the original LaTeX available for Copy. The pane shows
the converted plain text and any conversion diagnostics.

Selection highlights the entire equation in orange, or purple during its audio
request. It remains visible when other layout outlines are hidden. This does
not imply word/subexpression alignment. Selecting another equation, changing
page/document/revision, changing math language/style, or replacing rules retires
only that equation's speech. A newer prose request in the same player is preserved.

The debug slice requires selecting models and rules again after restarting the app.
It does not install a downloaded model or make a machine-specific directory a
shipping default. Cached pages can be restored after choosing the same bundle.

## Ownership and coordinates

PoDoFo supplies cheap document/page metadata and renders only when Rust grants
input capacity. Rendering holds `PdfSession.readLocked`, which serializes it
with editing, saving, and closing, and pins the PDF's native generation. It uses
white BGRA pixels without annotations or form overlays. The initial profile
renders at up to 144 dpi, with a 2048-pixel maximum edge and a byte-budget cap.
This is an experimental rendering profile. Real rendered formula pages are
covered by the M8/M9 plumbing checks; accuracy has its own corpus qualification.
Changing this policy changes the cache/render provenance.

Canonical coordinates are top-left points in the displayed page orientation.
pdfrx has already applied CropBox and rotation; the adapter scales pixel edges
to those page extents. Painting scales canonical coordinates directly into the
viewer's page rectangle. Applying `PdfRect.toRect` to these coordinates would
rotate them twice. Native tests check raster text against PDF text geometry for
all four rotations and a cropped page; reader tests paint real model output.

M8 transfers a fresh renderer allocation through the pinned native lease API
when no writable pixel view has escaped. Podoco retains it until its last native
reader stops and the independent release acknowledgement frees the allocation.
The renderer wrapper can be disposed immediately; page/document closure does
not invalidate the owned buffer. Exposed views and unsupported renderers use
the original copying path. That path copies the exclusively rendered image
into Podoco and immediately disposes the renderer image. There can be three
full-image allocations during this handoff: the renderer, Dart's native staging allocation, and Rust's owned copy.
The 16 MiB Rust input reservation does not include those transient application
copies; the current raster cap bounds each to 16 MiB. Core ML/preprocessing has
its own 128 MiB explicit tensor limit and, when enabled, a 48 MiB decoder-cache
limit; opaque framework allocations and model weights are additional.
The [M8 qualification](../podoco/docs/internal/m8-renderer-validation.md) establishes
zero pixel copies only at the renderer-to-Podoco lease handoff. Rendering,
preprocessing and Core ML tensors retain their own costs. The source exposes
`preferNativeLease: false` for the copied fallback and optional aggregate
`AnalysisImageTransfers` diagnostics.

## Persistence and invalidation

The app retains only the visible page snapshot in memory. Per-page JSON snapshots
live under application support in `podoco/pages-v2/`, with a 4 MiB page limit
and a 64 MiB disk limit. Old derived pages are evicted when the disk limit is
exceeded; scrolling to an evicted page shows no overlay until it is analyzed
again. No PDF bytes or user annotation records are modified by this cache.

Keys include an opaque hash of the document path, content/revision identity,
every ordered verified model-manifest hash, compute policy, pipeline profile,
and raster policy. Clean bytes
can reuse results after reopening. Unsaved edit revisions include a random
session identity so two different edit histories cannot share a cache key.

Every update checks document revision and analysis generation before receipt
and again after asynchronous staging, immediately before atomic publication.
Switching tabs, changing revision, closing the PDF, replacing the model, and
restarting analysis invalidate pending application work. Completed page snapshots
remain distinct from progressive app snapshots; a partial page is never relabeled
complete merely because a job stopped. A failed cache initialization stays
visible with an explicit retry control instead of background retries.

Formula updates merge into the same analysis/page snapshot without changing the
SDK's initial-layout event contract. A final page reconciles the complete result.
The old v1 cache is not read or automatically removed. Plain speech uses a separate
in-memory LRU capped at 256 entries and 4 MiB, keyed by LaTeX, display kind, complete
math options, SDK/converter profile, and rules manifest. Voice/speed changes reuse
plain text; model changes invalidate the selected page and playback intent.

See [M5 reader evidence](../podoco/docs/internal/m5-validation.md),
[M8 lease evidence](../podoco/docs/internal/m8-renderer-validation.md), and
[M9 integration evidence](../podoco/docs/internal/m9-integration-validation.md).
The reproducible native check is `tool/qualify_podoco_equations.py`; it uses local
assets and muted playback and does not stand in for human listening acceptance.
