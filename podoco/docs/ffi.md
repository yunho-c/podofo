# C ABI 2

Include the generated [`podoco.h`](../include/podoco.h) and link/load
`podoco_ffi`. Check `podoco_abi_version() == 2` **before resolving analysis
exports**. ABI 1 contains identity only and is deliberately rejected by the new
Dart package. `podoco_version()` still returns borrowed static NUL-terminated
UTF-8. ABI, package version, and JSON schema version are independent.

`podoco_features()` reports compiled image/job/Core ML support. Loaded-model
capabilities come from `podoco_analyzer_info`; a Core ML build does not imply
formula recognition or polygon support. Default portable builds provide image,
JSON, and transport contracts but cannot open the Core ML layout pipeline.

## Handles and buffers

`PodocoHandle` is an opaque, never-reused registry ID fitting signed 64 bits.
Zero is null. Stale/wrong-kind handles fail without dereferencing a foreign
address. Handles belong to this library instance; MLSR IDs are not interchangeable.
`podoco_release` releases any owned handle, treats zero as a no-op, and rejects
stale nonzero IDs. Concurrent operations retain an internal reference; native
work and release callbacks never run while the registry is locked.

Fallible operations return `PODOCO_OK`, `PODOCO_PENDING` for an empty poll, or
`PODOCO_ERROR`. Required output handles are cleared on failure/pending. An
optional error output owns a JSON `{code,message}` buffer. Use
`podoco_buffer_view`, copy its length-delimited UTF-8, then `podoco_release`.
The borrowed view remains valid until release; never release concurrently with
reading it. Outputs must be aligned, writable, and disjoint from inputs/each
other. Pointer validation checks lengths/layouts, not arbitrary address validity.
Panics are contained at C entry points; allocation aborts and foreign callbacks
violating their safety contract are not recoverable exceptions.

Metadata JSON is schema v0, at most 4 MiB. Source/sink failure replies are at
most 16 KiB. Semantic updates use the core's versioned `AnalysisUpdate` schema
and the analyzer's explicit maximum update size. Pixels, masks, and native
tensors never enter JSON. Every polled buffer owns its payload until release.

## Analyzer and job flow

1. Optionally call `podoco_bundle_verify` with an offline UTF-8 directory path.
   `podoco_analyzer_open` accepts `{schema_version:0,bundle_directory,options}`;
   options are the complete Rust `AnalyzerOptions` representation. These calls
   block on local verification/model loading and belong on a worker.
2. Read analyzer info, then call `podoco_job_start` with
   `{schema_version:0,document,pages,options}`. Pages are ordered metadata only;
   options are `AnalysisOptions`, with `formula_scope:"none"` for layout-only
   bundles. The core validates capabilities/profile before requesting pixels.
3. Drain `podoco_source_next` independently of results. Each request has a token,
   exact page descriptor, raster requirements, and a byte reservation. Render
   lazily, create/import an image, then `podoco_source_reply` with the token,
   image handle, and `{schema_version:0,page,pixel_to_page,render_profile}`.
   The reply borrows the image handle and retains its pixels on success: the
   caller always releases its own handle. Stale/duplicate replies leave that
   ownership intact; a cancelled polled request accepts a late reply for cleanup
   without prediction. Every polled request needs a completion reply, including
   after cancellation, before its input reservation can be released. `podoco_source_fail` supplies an owned error instead.
4. Drain `podoco_result_next`. Copy/decode and release the buffer before invoking
   application code. Call `podoco_result_ack` with its sequence only after the
   application sink finishes; empty error bytes mean success. One foreign sink
   call is in flight. A failed acknowledgement ends delivery.
5. Poll `podoco_job_progress` for coalesced progress/stop state and
   `podoco_job_outcome` for authoritative completion. A terminal processing
   notice is not proof of successful delivery. `podoco_job_cancel` is nonblocking
   and does not depend on source/result capacity.
6. Keep pumps alive during blocking `podoco_job_close`/`podoco_analyzer_close`.
   Then release handles. Last job-handle release without close abandons transport
   to unblock requests that the client can no longer answer; it does not claim
   that pending content was accepted.

`podoco_job_abandon` is the nonblocking emergency path for a binding protocol
failure. It preserves the handle for cleanup. `podoco_job_drain_state` reports
native producer completion and a frozen wake count without depending on JSON
schema decoding. Native sources observe cooperative cancellation on a 20 ms
control wait; this is not a total cancellation-latency promise.

## Wakeup and async-render lifetimes

Optional `PodocoWake` notifications carry only a caller-supplied scalar token.
They can occur before job-start returns, from any native worker. Enqueue work
and return promptly; never wait/close from the callback. Null selects polling.

Native outcome is published after source/sink workers exit. It includes the
frozen number of wake invocations, also available through `drain_state`.
Bindings must consume all those deferred notifications before closing their
callback. Cancellation withdraws unpolled requests; a polled request retains its input
reservation until the foreign renderer replies. Bindings must also drain any
deferred image-release notifications before acknowledging `DocumentFinished`,
so the next queued document cannot allocate while the previous one still owns
foreign pixels. The Dart implementation handles both boundaries.

## Images

`PodocoImageDescriptor` has fixed-width fields and an exact `struct_size`.
`podoco_image_copy` copies the full initialized byte view, including supplied
padding/trailing bytes. The caller may immediately overwrite/free its input.

`podoco_image_import` adopts a stable native allocation without copying pixels.
The caller excludes all writes and frees until the exactly-once release callback
receives its scalar token. The callback must remain callable, be thread-safe,
nonblocking, and never unwind. Rejection does not invoke it and leaves ownership
with the caller. Account for the whole retained allocation, not only visible
rows. Rust's advanced counterpart is `image::native::{NativeLease,import}`,
which returns the lease on rejection. The real PDF renderer adapter is M8;
M4 qualifies this ABI with a controlled allocator.

The foreign sink encodes one extra bounded result buffer, and callers may own
polled buffers or decoded values. These are explicit transport/caller storage,
separate from the core's serialized-queue reservation. Neither image import nor
resource counters imply zero-copy preprocessing or a process-memory cap.
