# M4 C/Dart layout SDK validation

Validated on 2026-10-26 in `feat/podoco`, building on M3 commit `6af6fc3`,
on macOS arm64/M4 Pro. ABI 2 exposes the real Rust analyzer to C and Dart.
The layout export remains experimental; formula recognition, MathCAT, the
PoDoFo renderer, and application behavior are subsequent milestones.

## Ownership and transport

The C layer uses non-reused typed handles, bounded versioned JSON, checked raw
image descriptors, and source/result rendezvous. The Rust analyzer still owns
scheduling, model sessions, and analysis semantics. Native wake/release callbacks
carry scalar tokens and run outside SDK locks. Input rejection preserves caller
ownership; an accepted native lease releases exactly once after its last reader.

Dart runs independent source, result, and control pumps. Sources render lazily,
async sinks acknowledge serially, and progress observation is optional. Native
opening, blocking close, and finalizer cleanup run off the caller isolate.
Same-analyzer waits inside source/sink callbacks are rejected. Disposal drains
foreign rendering, image release, result delivery, and queued wake notifications
before closing `NativeCallable` listeners. A separate scalar drain operation
allows cleanup even after a binding metadata/schema error.

Review found that withdrawing an already-polled source request on cancellation
could let the next document render before the first foreign renderer returned.
The corrected handshake retains that request's Rust input reservation until a
completion reply. Dart also waits for source/image-release cleanup before
acknowledging the terminal update. A queued-document regression checks that the
second source is not called while the cancelled first renderer still owns its
reservation. Emergency handle abandonment remains a distinct cleanup path.

## Portable checks

- Full `python3.13 tools/dev.py check`: formatting, Clippy, Rust unit/integration/
  doc tests, Rust documentation, generated header, compiled C identity caller,
  Dart analysis/tests, public example, relocated package, and rejection of an
  old identity-only ABI 1 library before resolving analysis symbols.
- `python3.13 tools/dev.py check-generated`: exact C/Dart bindings and mirrored
  canonical Rust schema fixtures.
- Rust 1.88 workspace tests with `coreml`, plus current-toolchain Core ML Clippy
  with warnings denied. Four portable FFI tests cover null/length/schema errors,
  contained panic, wrong/stale handles, independent copies, rejected ownership,
  pointer identity, and exact-once lease release from another thread.
- Six portable Dart tests cover identity, copied/native image disposal and
  rejection, canonical Rust result fixtures, deep immutability, optional fields,
  required variants/schema mismatch, and invalid semantic geometry/identities.

Native lease tests use controlled allocations. They qualify the SDK handoff,
not pdfrx ownership or a zero-copy renderer. `PageImage.copy` deliberately copies;
preprocessing and Core ML input tensors have separate allocations.

## Native checks

The ignored Rust FFI integration test compares three real page results with
blocking M2 control execution, checks seven ordered updates, and abandons a
second job after polling its source request to verify draining cleanup.

`tools/check_dart_jobs.py` passes 14 tests (six portable plus eight native).
The native group exercises three original page fixtures through both copying
and controlled native leases, exact M3 result equality, no progress subscriber,
unsupported recognition before rendering, slow/full sinks, cancellation during
late rendering, FIFO queue admission/cancellation, terminal delivery failure,
callback wait rejection, and repeated analyzer disposal. Native handle counts
and controlled allocation counts return to zero.

The public Dart CLI emits seven updates with six initial/final page snapshots
exactly matching Rust. A fresh consumer also builds through `coreml: true` in
the native-assets hook and repeats this CLI comparison. Mach-O inspection
records a macOS 15 deployment floor. This is a build-floor check, not execution
on macOS 15. No model download occurs.

The actual release `libpodoco_ffi.dylib` loads beside the existing MLSR dylib in
both orders in fresh processes. Each process calls MLSR identity and runs one
real Podoco layout job, with three updates, completed outcome, zero retained
handles, and no duplicate Objective-C registration warning. This does not
claim concurrent speech synthesis or audible playback qualification.

Reproduce with existing explicit assets:

```sh
PODOCO_M2_BUNDLE="$PWD/model-assets/pp-doclayout-v3-m2" \
  cargo test --locked -p podoco-ffi --features coreml \
  analysis_tests::native_document_transport_and_cancellation -- --ignored --exact
python3.13 tools/check_dart_jobs.py \
  --bundle model-assets/pp-doclayout-v3-m2 \
  --fixtures evaluation-output/m2-portable-v1 \
  --reference evaluation-output/m3-native/page_layout.jsonl \
  --output evaluation-output/m4-dart-native --hook-build
python3.13 tools/check_ffi_jobs.py \
  --podoco target/release/libpodoco_ffi.dylib \
  --mlsr /path/to/libmlsr_ffi.dylib \
  --bundle model-assets/pp-doclayout-v3-m2 \
  --output evaluation-output/m4-coexistence
```

The compact [summary](../../tests/fixtures/pp_doclayout_v3/m4-summary.json)
records source, native artifact, fixture, and reference hashes. Detailed logs
and JSONL remain under ignored `evaluation-output/m4-*`. This milestone adds
no layout-quality, ANE-placement, latency, or memory-performance claim; M2's
mixed-export promotion issues remain open.
