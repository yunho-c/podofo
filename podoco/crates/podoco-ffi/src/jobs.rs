use crate::{
    handles::{self, Entry, Kind},
    transport::{Bridge, ForeignSource, OwnedJob},
    types::*,
    wire::*,
};
use podoco::{
    Affine, AnalysisOptions, DocumentRef, Error, PageDescriptor, PageInput, ProfileId, Result,
};
use serde::Deserialize;
use std::sync::Arc;
fn with_job<T>(id: u64, f: impl FnOnce(&OwnedJob) -> Result<T>) -> Result<T> {
    let entry = handles::get(id, Kind::Job)?;
    let Entry::Job(job) = entry.as_ref() else {
        unreachable!()
    };
    f(job)
}
#[derive(Deserialize)]
struct Start {
    schema_version: u32,
    document: DocumentRef,
    pages: Vec<PageDescriptor>,
    options: AnalysisOptions,
}
#[derive(Deserialize)]
struct Rendered {
    schema_version: u32,
    page: PageDescriptor,
    pixel_to_page: Affine,
    render_profile: ProfileId,
}

/// Eagerly queue a document. Metadata: schema_version=0, document, ordered pages,
/// and AnalysisOptions. A required native sink is installed immediately; the
/// client must drain/ack results even without subscribing to progress.
/// # Safety
/// Metadata/outputs obey podoco_analyzer_open's contract. The optional wake
/// callback obeys PodocoWake's lifetime/thread contract. It may run before this
/// function returns, so it must enqueue a scalar notification, not reenter/wait.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn podoco_job_start(
    analyzer: PodocoHandle,
    metadata: PodocoBytes,
    wake: PodocoWake,
    wake_token: u64,
    output: *mut PodocoHandle,
    error: *mut PodocoHandle,
) -> PodocoStatus {
    // SAFETY: Exported input/output/callback contracts cover all accesses.
    unsafe {
        guard(error, || {
            clear(output)?;
            let config: Start = json(metadata)?;
            schema(config.schema_version)?;
            let entry = handles::get(analyzer, Kind::Analyzer)?;
            let Entry::Analyzer(a) = entry.as_ref() else {
                unreachable!()
            };
            let bridge = Arc::new(Bridge::new(wake, wake_token));
            let sink = bridge.clone();
            let max = a.limits.max_update_bytes();
            // Reserve a representable ID before callbacks can begin. Once admitted,
            // publication has no recoverable failure that could orphan wakeups.
            let handle = handles::reserve()?;
            let job = a.analyzer.analyze_document(
                ForeignSource {
                    document: config.document,
                    pages: config.pages,
                    bridge: bridge.clone(),
                },
                config.options,
                move |update| sink.deliver(update, max),
            )?;
            handles::publish(handle, Entry::Job(OwnedJob { job, bridge }));
            output.write(handle);
            Ok(PODOCO_OK)
        })
    }
}
/// Pull one lazy source request as an owned schema-v0 JSON buffer. PENDING
/// returns output=0. Request JSON includes token, page, requirements, byte_budget.
/// Polling never performs rendering or waits for a worker. Once polled, every
/// request requires a completion reply, including after cancellation; its input
/// reservation remains held until that reply. Unpolled requests may be withdrawn.
/// # Safety
/// Outputs follow podoco_buffer_view's contract.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn podoco_source_next(
    job: PodocoHandle,
    output: *mut PodocoHandle,
    error: *mut PodocoHandle,
) -> PodocoStatus {
    // SAFETY: Exported output contract.
    unsafe {
        guard(error, || {
            clear(output)?;
            with_job(job, |j| {
                if let Some(bytes) = j.bridge.source_next() {
                    output.write(handles::insert(Entry::Buffer(bytes))?);
                    Ok(PODOCO_OK)
                } else {
                    Ok(PODOCO_PENDING)
                }
            })
        })
    }
}
/// Reply to a polled source token with an image and schema-v0 page/map/profile
/// metadata. This borrows the image HANDLE and retains its pixels on success;
/// the caller always releases its own image handle afterward. Stale/duplicate
/// replies fail without consuming ownership. A cancelled polled request accepts
/// a late reply solely for release, without prediction. Never write into an imported image.
/// # Safety
/// Metadata/error follow podoco_analyzer_open's input/output contract.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn podoco_source_reply(
    job: PodocoHandle,
    token: u64,
    image: PodocoHandle,
    metadata: PodocoBytes,
    error: *mut PodocoHandle,
) -> PodocoStatus {
    // SAFETY: Exported borrowed-input/error-output contract.
    unsafe {
        guard(error, || {
            let rendered: Rendered = json(metadata)?;
            schema(rendered.schema_version)?;
            let entry = handles::get(image, Kind::Image)?;
            let Entry::Image(image) = entry.as_ref() else {
                unreachable!()
            };
            let input = PageInput::new(
                rendered.page,
                image.clone(),
                rendered.pixel_to_page,
                rendered.render_profile,
            )
            .map_err(|e| e.error)?;
            with_job(job, |j| j.bridge.source_reply(token, Ok(input)))?;
            Ok(PODOCO_OK)
        })
    }
}
/// Fail a polled source request with a UTF-8 JSON Error {code,message} (at most
/// 16 KiB). Use page_source for render failure or source_changed for revision
/// change; the Rust job determines whether analysis may continue.
/// # Safety
/// Failure/error follow the standard readable-input/writable-output contract.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn podoco_source_fail(
    job: PodocoHandle,
    token: u64,
    failure: PodocoBytes,
    error: *mut PodocoHandle,
) -> PodocoStatus {
    // SAFETY: Exported input/output contract.
    unsafe {
        guard(error, || {
            let failure = parse_failure(failure)?;
            with_job(job, |j| j.bridge.source_reply(token, Err(failure)))?;
            Ok(PODOCO_OK)
        })
    }
}
unsafe fn parse_failure(bytes: PodocoBytes) -> Result<Error> {
    // SAFETY: Caller forwards the exported readable bytes contract.
    let bytes = unsafe { input(bytes, 16 * 1024) }?;
    serde_json::from_slice(bytes).map_err(|e| invalid(format!("failure JSON: {e}")))
}
/// Pull the next semantic AnalysisUpdate buffer, or PENDING with output=0.
/// There is one in-flight foreign sink call. Copy/decode and release the buffer
/// before invoking user code; acknowledge its sequence only after the async sink
/// completes. Source/control polling remains independent of this acknowledgement.
/// # Safety
/// Outputs follow podoco_buffer_view's contract.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn podoco_result_next(
    job: PodocoHandle,
    output: *mut PodocoHandle,
    error: *mut PodocoHandle,
) -> PodocoStatus {
    // SAFETY: Exported output contract.
    unsafe {
        guard(error, || {
            clear(output)?;
            with_job(job, |j| {
                if let Some(bytes) = j.bridge.result_next() {
                    output.write(handles::insert(Entry::Buffer(bytes))?);
                    Ok(PODOCO_OK)
                } else {
                    Ok(PODOCO_PENDING)
                }
            })
        })
    }
}
/// Acknowledge a previously polled update sequence. Empty failure bytes mean
/// success; otherwise provide Error JSON (at most 16 KiB) and delivery fails.
/// Cancellation does not fabricate an acknowledgement: keep the sink pump alive
/// until its active callback and terminal processing notice have drained.
/// # Safety
/// Failure/error follow the standard input/output contract.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn podoco_result_ack(
    job: PodocoHandle,
    sequence: u64,
    failure: PodocoBytes,
    error: *mut PodocoHandle,
) -> PodocoStatus {
    // SAFETY: Exported input/output contract.
    unsafe {
        guard(error, || {
            let result = if failure.len == 0 {
                Ok(())
            } else {
                Err(parse_failure(failure)?)
            };
            with_job(job, |j| j.bridge.result_ack(sequence, result))?;
            Ok(PODOCO_OK)
        })
    }
}
/// Request cancellation without waiting for rendering, native inference, or a
/// sink. Safe while result capacity is exhausted. Keep all pumps running.
/// # Safety
/// Optional error output follows the standard contract.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn podoco_job_cancel(
    job: PodocoHandle,
    error: *mut PodocoHandle,
) -> PodocoStatus {
    // SAFETY: Exported error-output contract.
    unsafe {
        guard(error, || {
            with_job(job, |j| {
                j.job.cancel();
                Ok(())
            })?;
            Ok(PODOCO_OK)
        })
    }
}
/// Read coalesced schema-v0 progress and stopping state. Stopping also includes
/// internal failure, so a binding can cancel an outstanding renderer when a
/// sink fails. Observation neither starts nor consumes result delivery.
/// # Safety
/// Outputs follow podoco_buffer_view's contract.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn podoco_job_progress(
    job: PodocoHandle,
    output: *mut PodocoHandle,
    error: *mut PodocoHandle,
) -> PodocoStatus {
    // SAFETY: Exported output contract.
    unsafe {
        guard(error, || {
            clear(output)?;
            with_job(job, |j| {
                output.write(buffer(
                    &serde_json::json!({"schema_version":0,
                "analysis_id":j.job.id(),"progress":j.job.progress(),"stopping":j.job.cancellation().is_cancelled()}),
                    PODOCO_MAX_METADATA_BYTES,
                )?);
                Ok(PODOCO_OK)
            })
        })
    }
}
/// Read the immutable schema-v0 authoritative outcome after native callbacks
/// have drained; PENDING returns output=0. A binding must additionally await its
/// own cancelled/late async renderer before completing disposal and closing wake
/// callbacks. Use this control poll even after the terminal result was acked.
/// # Safety
/// Outputs follow podoco_buffer_view's contract.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn podoco_job_outcome(
    job: PodocoHandle,
    output: *mut PodocoHandle,
    error: *mut PodocoHandle,
) -> PodocoStatus {
    // SAFETY: Exported output contract.
    unsafe {
        guard(error, || {
            clear(output)?;
            with_job(job, |j| {
                if let Some(outcome) = j.job.try_outcome() {
                    output.write(buffer(
                    &serde_json::json!({"schema_version":0,"outcome":outcome,"wake_count":j.bridge.wake_count()}),
                        PODOCO_MAX_METADATA_BYTES,
                    )?);
                    Ok(PODOCO_OK)
                } else {
                    Ok(PODOCO_PENDING)
                }
            })
        })
    }
}
/// Cancel and wait for native work/source/sink drain; idempotent. This blocks,
/// so bindings run it on a separate worker and keep source/result pumps alive.
/// Release the handle only afterward. Last-handle release without close abandons
/// delivery as an emergency cleanup path, rather than claiming accepted results.
/// # Safety
/// Optional error output follows the standard contract.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn podoco_job_close(
    job: PodocoHandle,
    error: *mut PodocoHandle,
) -> PodocoStatus {
    // SAFETY: Exported error-output contract.
    unsafe {
        guard(error, || {
            with_job(job, |j| j.job.close())?;
            Ok(PODOCO_OK)
        })
    }
}

/// Emergency transport failure: cancel work and reject further source/results,
/// unblocking a sink whose binding cannot decode/ack it. Nonblocking. Keep the
/// handle and wake callback alive until outcome is ready, then drain the reported
/// wake_count before closing the callback. This is not successful delivery.
/// # Safety
/// Optional error output follows the standard contract.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn podoco_job_abandon(
    job: PodocoHandle,
    error: *mut PodocoHandle,
) -> PodocoStatus {
    // SAFETY: Exported error-output contract.
    unsafe {
        guard(error, || {
            with_job(job, |j| {
                j.bridge.abandon();
                j.job.cancel();
                Ok(())
            })?;
            Ok(PODOCO_OK)
        })
    }
}

/// Independent callback-lifetime control, even if a client cannot decode outcome
/// JSON. PENDING means producers may still run. OK writes the frozen number of
/// scalar wake calls after native work/callbacks have drained. Consume that many
/// binding notifications before closing PodocoWake. This does not acknowledge
/// semantic results or claim delivery success.
/// # Safety
/// Count/error outputs are aligned, writable, non-null (count), and disjoint.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn podoco_job_drain_state(
    job: PodocoHandle,
    count: *mut u64,
    error: *mut PodocoHandle,
) -> PodocoStatus {
    // SAFETY: Exported disjoint output contract.
    unsafe {
        guard(error, || {
            clear(count)?;
            with_job(job, |j| {
                if j.job.try_outcome().is_some() {
                    count.write(j.bridge.wake_count());
                    Ok(PODOCO_OK)
                } else {
                    Ok(PODOCO_PENDING)
                }
            })
        })
    }
}
