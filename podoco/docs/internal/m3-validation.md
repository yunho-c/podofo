# M3 document-job validation

Validated on 2026-10-26 in `feat/podoco`, building on M2 commit `a6562f4`.
The host remains macOS arm64/M4 Pro. This milestone adds Rust jobs, not C/Dart
analysis, formula inference, or production promotion of the mixed layout export.

## Implemented boundary

`jobs` adds one FIFO scheduler, a lazy source worker and serial delivery worker
for the active job, source reservations, bounded encoded updates, progress,
cooperative cancellation, and draining shutdown. The scheduler owns a safe M2
session handle; native objects remain confined to that session's original
worker. No new native `Send`/`Sync` implementation was added. Sources/sinks run
outside locks, with reentrant same-analyzer waits rejected.

The initial implementation deliberately has zero speculative prefetch. This
satisfies the design's maximum of one prefetched page without selecting an
unqualified page-resolution default. One-shot page jobs also render lazily.
The only new production dependency is pinned `getrandom 0.4.3`, already present
transitively in the lockfile, for independent 128-bit analysis identities.

## Lifecycle evidence

Twenty deterministic private-pipeline tests cover:

- eager completion with no progress subscription; sequence and acknowledgement
  counts; repeated and concurrent close;
- a blocked sink with full update count, byte-limit backpressure with spare item
  capacity, and a single oversized update/terminal notice;
- cancellation while queued, during rendering/prediction, between formulas,
  and while delivery is blocked; queued jobs never render;
- source input release before layout-only backpressure, preservation during
  native work, and exactly-once release of late/cancelled/rejected inputs;
- source revision change during rendering, wrong returned identity, oversize
  buffers, recoverable page failures, failed/panicking sinks and sources, and
  an unexpected pipeline panic with active/queued work;
- a sink failure while the next source callback is waiting: the independent
  abort flag wakes its cancellation token without relabeling failure as user
  cancellation;
- terminal-notice failure after completed processing, preserving the distinct
  failed overall outcome and completed processing summary;
- formula recognized/failed/truncated events, final-state agreement, and pending
  counts after cancellation, using only a private fake pipeline.

An aggregate run exposed a missing progress notification before a producer
blocked on result capacity. The implementation now publishes page completion
and input release under the same state guard and notifies before that wait;
the slow-sink regression then passed. Input reservations also remain charged
until a cancelled renderer returns. Result accounting uses buffer capacity,
including the producer reservation, rather than only serialized length.

Callback panic containment does not cover aborting allocation failure or a
foreign callback that violates Rust's unwind contract. No test pretends that
arbitrary stuck caller code or an active native prediction can be interrupted.

## Native parity and model reuse

The opt-in native test runs three original fixtures through the blocking M2
session, then two three-page jobs through that same session: nine predictions,
one successful model load. Both initial and final snapshots compare exactly
with the control, including provenance and the raster fixture's rotated map.
Every job acknowledges seven updates and three completed pages. Input, tensor,
result-byte, and update-count observations stay within the supplied limits;
input/result charges return to zero after completion.

The public PNG document example and M2 page example also run independently on
the same three fixtures (six more predictions). Their page objects are exactly
equal. The document's terminal summary matches its authoritative outcome,
sequences are 0–6, and delivery/resource counters agree. The examples use pixel
coordinates; rotated mapping is exercised by the native test above.

Reproduce with existing local model assets; no Python ML dependencies or
downloads are required:

```sh
python3.13 tools/pp_doclayout_v3/check_jobs.py \
  --bundle model-assets/pp-doclayout-v3-m2 \
  --output evaluation-output/m3-native
```

The compact [summary](../../tests/fixtures/pp_doclayout_v3/m3-summary.json)
records source/fixture/manifest hashes and counters. Full JSONL outputs and
test/build logs remain under the ignored output directory. This is integration
parity, not a new layout-quality benchmark, memory measurement, ANE-placement
claim, or timing comparison. M2's two extra detections and order differences
remain experimental promotion blockers.

## Development checks

- `python3.13 tools/dev.py check`: formatting, portable Clippy/tests, Rust docs,
  header freshness, C identity smoke, Dart format/analyze/test/example,
  relocated package, and incompatible-library rejection.
- `cargo +1.88.0 test --locked --workspace --features coreml`: MSRV with the
  native dependency; 31 core unit tests, seven bundle tests, ten contract tests,
  one FFI test and one doctest pass; four asset-dependent tests are opt-in.
- `cargo clippy --locked --workspace --all-targets --features coreml -- -D warnings`.
- `python3.13 tools/dev.py check-generated`: C/Dart bindings are unchanged.
- Ruff for the qualification helper and `git diff --check`.

Existing C/Dart tests still exercise the identity ABI only; usable foreign
document analysis remains M4. Real formula events, math conversion, renderer
leases, and application acceptance remain their later milestone gates.
