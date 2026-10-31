# M8 native renderer lease qualification

Qualified 2026-10-26 on M4 Pro/macOS 27.0.1, Flutter 3.47.5/Dart 3.13.4.
PoDoFo's dedicated analysis renderer now transfers fresh native BGRA storage
through a reviewed, pinned pdfrx_engine 0.6.1 extension. The app retains the
copied fallback. This qualifies zero pixel copies at that handoff only;
preprocessing, Core ML input/output tensors and PDF rasterization are unchanged.

## Source and ownership

The published engine archive is pinned by SHA-256
`f74ca9ea4ec722545f054a1d6ee1bf01222409ecd9458e5945c0cc5feaa3d2c6`, under MIT.
A 53-file source/documentation inventory, reviewed patch and provenance live
under `podofo_frontend_one/third_party`; `tool/verify_pdfrx_engine.py` checks the
exact bytes before app Podoco preparation. The local pdfrx package resolves that
relative engine path. The registry cache and sibling checkout remain untouched.
PDFium's locked dependency is unchanged.

PDFium renders into its existing malloc-owned BGRA allocation. Its native page
and bitmap are closed before the resulting image reaches Dart. The new lease
moves this same pointer out of the image. The transfer is refused if the writable
`pixels` view was ever read; unsupported managed/web implementations also return
null. Original image disposal after transfer cannot free the lease. A lease has
no pixel-list API; address access is an advanced immutable-reader contract.

Only exclusive leases receive a native finalizer, using the allocator's native
free function. Explicit release detaches it and frees once. Legacy images with
escaped typed-data views retain their explicit-lifetime behavior. The production
adapter passes the pointer directly to `PageImage.importNative`; its release
closure retains the lease until Rust's final reader drops and Dart receives the
independent release notification. Import rejection frees the caller-owned lease.
No viewer image or writable pixel view enters the production analysis path.

## Native tests and real model parity

Eight explicit tests passed without skips using a PDF image XObject built
losslessly from the first M6 document raster (IBEM page `0001074_page02`).
This PDF is rendered by actual PDFium before analysis; it is not a direct raw
image import. The raster is 1447 × 2048, 11,853,824 BGRA bytes. Fixture and source
hashes are retained in the [compact report](../../tests/fixtures/m8-renderer-summary.json).

- Exclusive buffers survive image/document disposal and 32 MiB of Dart allocation
  pressure with unchanged pointer and pixel hash; explicit release is idempotent.
  This is GC-pressure coverage, not a claim that a forced collection was observed.
- Exposed writable views and managed images use the copy fallback.
- Oversized import rejection and successful imports both end with matching
  renderer-transfer/release counters and zero retained lease bytes.
- Copied and leased real layout/formula jobs produce exactly equal semantic
  payloads, including **eight recognized formulas per run**, with a slow sink.
- Cancellation after rendering but before source delivery permits document closure,
  preserves the allocation until the late image returns, and releases before done.
- A failed layout sink drains ownership; the same analyzer then completes a fresh
  layout job. Cancellation after the first formula also drains renderer ownership.

Each test ends with zero Podoco handles. Actual malloc/free sites and the
finalizer detach path were source-audited; counters are taken at the transfer
and explicit release boundary. Existing Rust scheduler tests separately cover
cancellation during a blocked native prediction and fatal worker teardown.
All-profile correctness does not imply model quality: M2/M6 recall, export and
recognition limitations remain unchanged.

## Copies, bounds and handoff timing

The copied path makes two full-image pixel copies: renderer → native staging,
then staging → Rust-owned storage. Three image allocations can overlap. The
leased path retains the single renderer allocation and copies no pixels at this
handoff. For this fixture, the copy path transfers 11,853,824 bytes on each copy
leg; the lease path reports zero copied bytes and one matched allocation/release.
The logical job input reservation peaks at 16 MiB for both; the tracked live
renderer lease peaks at 11,853,824 bytes and returns to zero. Neither is RSS or
an accounting of opaque Core ML allocations.

A separate active-host diagnostic performs four warmup pairs, then 20 alternating
copy/lease pairs using fresh actual renders. Only `analysisImageInput` wall time
is measured; rendering and asynchronous release are excluded. Measurements are
from a single process on this host, with raw samples retained. Power/thermal
conditions were not captured, so these remain active-host diagnostics:

| Handoff | Median | Minimum–maximum |
|---|---:|---:|
| Copied | 570.5 µs | 419–983 µs |
| Native lease | 154 µs | 113–345 µs |

These numbers describe the handoff boundary, not page inference throughput or
a general platform speedup. The real-model job comparison is correctness
qualification and is not mixed into these timings.

The broader app suite passed **279 tests with six explicit skips**: four existing
opt-in MLSR tests and two M8 corpus/benchmark tests covered separately above.
Flutter analysis, the host-arm64 Release build and deep/strict local signing
verification passed. Their logs and hashes are recorded in the compact report.

## Reproduce

From `podofo_frontend_one/`, using the existing offline M6 assets:

```sh
python3.13 tool/qualify_podoco_leases.py \
  --layout ../podoco/model-assets/pp-doclayout-v3-m2 \
  --formula ../podoco/model-assets/pp-formulanet-plus-l-m6 \
  --pages ../podoco/evaluation-output/m6-documents-v1/pages.json \
  --output build/podoco-qualification/m8-native-new \
  --flutter-sdk /Users/yunhocho/fvm/versions/3.47.5
```

Final focused evidence is `build/podoco-qualification/m8-native-v3/`, including
native test logs, complete copied/leased payloads, raw handoff samples, model and
binary hashes, and source-drift checks (no failures). Earlier basic runs caught
a capability-dispatch recursion, fixed by making the capability a PdfImage
subtype with a distinct transfer method. Failed runs and lint failures are
retained and are not passing qualification evidence.
