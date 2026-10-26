# Experimental document layout analysis

PoDoFo's M5 integration uses the public Podoco Dart SDK for PP-DocLayoutV3 layout
analysis on macOS Apple Silicon. The selected mixed-precision layout profile is
experimental. Formula regions are detected, but recognition, Copy LaTeX, and
Listen are not enabled yet. Those require the subsequent formula/math milestones.

## Build and use

Prepare the existing [MLSR dependency](tts-implementation.md#build-preparation),
then run from `podofo_frontend_one/` with the pinned Flutter 3.47.5 toolchain:

```sh
python3.13 tool/prepare_podoco.py
flutter pub get --enforce-lockfile
bash tool/build_macos_local.sh release
```

The new helper builds this checkout's Rust SDK into ignored `.podoco/native/`.
It enables Core ML on macOS arm64 and builds a portable artifact on other
supported desktop hosts. It does not fetch models. The local build helper keeps
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

The debug slice requires selecting the model again after restarting the app.
It does not install a downloaded model or make a machine-specific directory a
shipping default. Cached pages can be restored after choosing the same bundle.

## Ownership and coordinates

PoDoFo supplies cheap document/page metadata and renders only when Rust grants
input capacity. Rendering holds `PdfSession.readLocked`, which serializes it
with editing, saving, and closing, and pins the PDF's native generation. It uses
white BGRA pixels without annotations or form overlays. The initial profile
renders at up to 144 dpi, with a 2048-pixel maximum edge and a byte-budget cap.
This is an experimental layout integration profile, not qualified formula-crop
resolution. Changing it changes the cache/render provenance.

Canonical coordinates are top-left points in the displayed page orientation.
pdfrx has already applied CropBox and rotation; the adapter scales pixel edges
to those page extents. Painting scales canonical coordinates directly into the
viewer's page rectangle. Applying `PdfRect.toRect` to these coordinates would
rotate them twice. Native tests check raster text against PDF text geometry for
all four rotations and a cropped page; reader tests paint real model output.

M5 copies the exclusively rendered image into Podoco and immediately disposes
the renderer image. There can be three full-image allocations during this
handoff: the renderer, Dart's native staging allocation, and Rust's owned copy.
The 16 MiB Rust input reservation does not include those transient application
copies; the current raster cap bounds each to 16 MiB. Core ML/preprocessing has
its own 96 MiB explicit tensor limit; opaque framework allocations are additional.
M8 separately qualifies a native renderer lease. No M5 zero-copy claim is made.

## Persistence and invalidation

The app retains only the visible page snapshot in memory. Per-page JSON snapshots
live under application support in `podoco/pages-v1/`, with a 256 KiB page limit
and a 64 MiB disk limit. Old derived pages are evicted when the disk limit is
exceeded; scrolling to an evicted page shows no overlay until it is analyzed
again. No PDF bytes or user annotation records are modified by this cache.

Keys include an opaque hash of the document path, content/revision identity,
verified model-manifest hash, pipeline profile, and raster policy. Clean bytes
can reuse results after reopening. Unsaved edit revisions include a random
session identity so two different edit histories cannot share a cache key.

Every update checks document revision and analysis generation before receipt
and again after asynchronous staging, immediately before atomic publication.
Switching tabs, changing revision, closing the PDF, replacing the model, and
restarting analysis invalidate pending application work. Completed page snapshots
remain distinct from progressive layouts; a partial page is never relabeled
complete merely because a job stopped. A failed cache initialization stays
visible with an explicit retry control instead of background retries.

[Validation evidence](../podoco/docs/internal/m5-validation.md) records the current
checks. The complete Copy/Listen workflow and model-profile promotion remain
separate qualification gates.
