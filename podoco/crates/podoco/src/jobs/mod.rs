//! Eager, bounded document jobs with lazy sources and required serial sinks.
mod engine;
#[cfg(test)]
mod tests;

use crate::{
    AnalysisId, AnalysisOptions, AnalysisUpdate, AnalyzerOptions, Capabilities, DocumentRef, Error,
    ErrorCode, ModelBundle, PageDescriptor, PageInput, PixelFormat, Result,
    results::{AnalysisCounts, AnalysisSummary, CompletionStatus},
};
use serde::Serialize;
use std::{
    cell::Cell,
    collections::VecDeque,
    sync::{Arc, Condvar, Mutex, MutexGuard},
    thread::JoinHandle,
    time::Duration,
};

/// Rendering requirements; resolution is chosen by the source's qualified
/// render profile subject to the reservation, never silently downscaled by jobs.
#[derive(Clone, Debug, Serialize)]
pub struct RasterRequirements {
    /// Preferred renderer format. Both BGRA8 and RGBA8 remain accepted.
    pub preferred_format: PixelFormat,
    /// Preprocessing background, in RGB bytes.
    pub background_rgb: [u8; 3],
}
/// One lazy source request, issued only after reserving input capacity.
#[derive(Clone)]
pub struct PageRequest {
    /// Exact snapshotted source descriptor.
    pub page: PageDescriptor,
    /// Pipeline rendering requirements.
    pub requirements: RasterRequirements,
    /// Maximum retained image allocation, including padding and trailing bytes.
    pub byte_budget: u64,
    /// Cooperative cancellation; arbitrary caller code cannot be interrupted.
    pub cancellation: CancellationHandle,
}
/// Immutable document metadata plus a lazy renderer. Metadata accessors must be
/// cheap and must not render pages. Rendering runs on an SDK source worker.
pub trait PageSource: Send + 'static {
    /// Immutable document identity/revision.
    fn document(&self) -> &DocumentRef;
    /// Ordered page subset without raster storage; duplicates are rejected.
    fn pages(&self) -> &[PageDescriptor];
    /// Render the requested page within its byte reservation. Finish promptly
    /// after cancellation; late returned images are released by the SDK.
    fn load_page(&mut self, request: PageRequest) -> Result<PageInput>;
}

/// Coalesced job lifecycle, independent of optional progress observation.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum JobPhase {
    /// Accepted but not rendering or running a model.
    Queued,
    /// Processing the ordered page subset.
    Running,
    /// Processing ended; callbacks and delivery are draining.
    Finishing,
    /// Immutable authoritative outcome is available.
    Finished,
}
/// Acknowledged delivery, separate from model-processing counts.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize)]
pub struct DeliveryCounts {
    /// Sink calls that returned success.
    pub updates_acknowledged: u64,
    /// Most recent successfully acknowledged sequence, if any.
    pub last_sequence: Option<u64>,
    /// Acknowledged authoritative page snapshots.
    pub pages_finished: u64,
    /// Acknowledged individual terminal formula updates.
    pub formulas_finished: u64,
    /// Whether the terminal processing notice was acknowledged.
    pub document_finished: bool,
}
/// Snapshot only; reading progress never consumes or starts result delivery.
#[derive(Clone, Debug, Serialize)]
pub struct AnalysisProgress {
    /// Current lifecycle phase.
    pub phase: JobPhase,
    /// Cooperative cancellation was requested.
    pub cancellation_requested: bool,
    /// Work completed by the pipeline, including undelivered results.
    pub processed: AnalysisCounts,
    /// Successfully acknowledged updates.
    pub delivered: DeliveryCounts,
    /// Source reservation or retained input bytes, zero after native drain.
    pub input_bytes: u64,
    /// Serialized buffer capacities (queued/in-flight), plus the producer's
    /// maximum-size reservation; released only on acknowledgement.
    pub pending_result_bytes: u64,
    /// Queued/in-flight updates, including an active sink call.
    pub pending_updates: u32,
    /// Peak input reservation; a source initially reserves the full input limit.
    pub peak_input_bytes: u64,
    /// Peak serialized capacities and producer reservation.
    pub peak_result_bytes: u64,
    /// Peak queued/in-flight update count.
    pub peak_pending_updates: u32,
}
/// Authoritative completion, published after native work and source/sink calls
/// drain. Delivery failure can make `status` failed even when processing finished.
#[derive(Clone, Debug, Serialize)]
pub struct AnalysisOutcome {
    /// Overall processing/cancellation/delivery outcome.
    pub status: CompletionStatus,
    /// Processing-only summary, also used by `DocumentFinished`.
    pub summary: AnalysisSummary,
    /// Acknowledgements including the terminal notice, when successful.
    pub delivered: DeliveryCounts,
    /// Fatal processing or delivery error. Partial page failures live in updates.
    pub error: Option<Error>,
    /// Final bounded-resource observations.
    pub progress: AnalysisProgress,
}

/// Cloneable control handle without native objects or ownership of job disposal.
#[derive(Clone)]
pub struct CancellationHandle {
    shared: Arc<JobShared>,
}
impl CancellationHandle {
    /// Request cancellation without waiting for rendering, inference, or a sink.
    pub fn cancel(&self) {
        let mut state = self.shared.lock();
        if state.outcome.is_none() && !state.delivery_done {
            state.progress.cancellation_requested = true;
            self.shared.changed.notify_all();
        }
    }
    /// Whether user cancellation or a fatal job failure requested a stop.
    pub fn is_cancelled(&self) -> bool {
        let state = self.shared.lock();
        state.progress.cancellation_requested || state.abort_requested
    }
    /// Wait for cancellation up to the supplied timeout. Useful for cooperative
    /// source code; returns true when cancellation has been requested.
    pub fn wait_cancelled(&self, timeout: Duration) -> bool {
        let state = self.shared.lock();
        let (state, _) = self
            .shared
            .changed
            .wait_timeout_while(state, timeout, |s| {
                !s.progress.cancellation_requested && !s.abort_requested && s.outcome.is_none()
            })
            .unwrap_or_else(|p| p.into_inner());
        state.progress.cancellation_requested || state.abort_requested
    }
}

/// Eager owned job. Drop cancels and waits; explicit close is preferable. Never
/// wait/close from this analyzer's source or sink callback; cancellation is safe.
pub struct AnalysisJob {
    shared: Arc<JobShared>,
}
impl AnalysisJob {
    /// Unique opaque identity for this run, including retries.
    pub fn id(&self) -> &AnalysisId {
        &self.shared.id
    }
    /// Independent lightweight cancellation handle.
    pub fn cancellation(&self) -> CancellationHandle {
        CancellationHandle {
            shared: self.shared.clone(),
        }
    }
    /// Nonblocking idempotent cancellation request.
    pub fn cancel(&self) {
        self.cancellation().cancel();
    }
    /// Latest coalesced progress; no subscription is needed for completion.
    pub fn progress(&self) -> AnalysisProgress {
        self.shared.lock().progress.clone()
    }
    /// Nonblocking authoritative completion snapshot, once callbacks have drained.
    /// Transport pumps may poll this independently of result delivery.
    pub fn try_outcome(&self) -> Option<AnalysisOutcome> {
        self.shared.lock().outcome.clone()
    }
    /// Wait for the authoritative immutable outcome, including sink failures.
    pub fn wait(&self) -> Result<AnalysisOutcome> {
        reject_callback_wait(self.shared.owner)?;
        let mut state = self.shared.lock();
        while state.outcome.is_none() {
            state = self.shared.wait(state);
        }
        Ok(state.outcome.as_ref().expect("outcome checked").clone())
    }
    /// Cancel unfinished work and wait for release/callback drain. Repeated calls
    /// succeed; processing failures are returned by `wait`, not by cleanup.
    pub fn close(&self) -> Result<()> {
        self.cancel();
        self.wait().map(|_| ())
    }
}
impl Drop for AnalysisJob {
    fn drop(&mut self) {
        let _ = self.close();
    }
}

type Sink = Box<dyn FnMut(AnalysisUpdate) -> Result<()> + Send>;
struct EncodedUpdate {
    bytes: Vec<u8>,
    terminal: bool,
}
struct State {
    abort_requested: bool,
    progress: AnalysisProgress,
    queue: VecDeque<EncodedUpdate>,
    request: Option<PageDescriptor>,
    reply: Option<Result<PageInput>>,
    source_stop: bool,
    source_done: bool,
    processing_done: bool,
    delivery_done: bool,
    delivery_error: Option<Error>,
    outcome: Option<AnalysisOutcome>,
}
struct JobShared {
    owner: u64,
    id: AnalysisId,
    document: DocumentRef,
    state: Mutex<State>,
    changed: Condvar,
}
impl JobShared {
    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|p| p.into_inner())
    }
    fn wait<'a>(&self, guard: MutexGuard<'a, State>) -> MutexGuard<'a, State> {
        self.changed.wait(guard).unwrap_or_else(|p| p.into_inner())
    }
    fn cancelled(&self) -> bool {
        self.lock().progress.cancellation_requested
    }
}
struct QueuedJob {
    shared: Arc<JobShared>,
    pages: Vec<PageDescriptor>,
    source: Box<dyn PageSource>,
    sink: Sink,
    options: AnalysisOptions,
}
struct QueueState {
    closed: bool,
    failure: Option<Error>,
    queue: VecDeque<QueuedJob>,
    active: Option<Arc<JobShared>>,
}
struct QueueShared {
    state: Mutex<QueueState>,
    changed: Condvar,
}
impl QueueShared {
    fn lock(&self) -> MutexGuard<'_, QueueState> {
        self.state.lock().unwrap_or_else(|p| p.into_inner())
    }
}

/// One persistent inference lane with bounded FIFO admission. Sources render
/// only when active and after a byte reservation. No speculative prefetch in v0.
pub struct Analyzer {
    owner: u64,
    queue: Arc<QueueShared>,
    worker: Mutex<Option<JoinHandle<()>>>,
    capabilities: Capabilities,
    profile: String,
    options: AnalyzerOptions,
}
impl Analyzer {
    /// Load the selected native layout pipeline and start its scheduler.
    pub fn open(bundle: ModelBundle, options: AnalyzerOptions) -> Result<Self> {
        let profile = bundle.manifest().profile.id.clone();
        let session = crate::LayoutSession::open(bundle, options.clone())?;
        Self::start(
            Box::new(engine::LayoutPipeline { session }),
            profile,
            options,
        )
    }
    /// Loaded pipeline operations; unavailable recognition fails before rendering.
    pub fn capabilities(&self) -> Capabilities {
        self.capabilities
    }

    /// Snapshot source metadata/options, accept a required sink, and eagerly queue
    /// work. A full job queue returns `LimitExceeded` without invoking the renderer.
    pub fn analyze_document<S, F>(
        &self,
        source: S,
        options: AnalysisOptions,
        sink: F,
    ) -> Result<AnalysisJob>
    where
        S: PageSource,
        F: FnMut(AnalysisUpdate) -> Result<()> + Send + 'static,
    {
        self.capabilities.validate(&options)?;
        if options.profile.as_str() != self.profile {
            return Err(Error::input("analysis profile does not match analyzer"));
        }
        let (document, pages) = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            (source.document().clone(), source.pages().to_vec())
        }))
        .map_err(|_| Error::new(ErrorCode::PageSource, "source metadata accessor panicked"))?;
        crate::domain::validate_pages(&document, &pages)?;
        let mut random = [0u8; 16];
        getrandom::fill(&mut random)
            .map_err(|e| Error::new(ErrorCode::WorkerFailed, format!("analysis ID: {e}")))?;
        let id = AnalysisId::new(format!("podoco-{:032x}", u128::from_le_bytes(random)))?;
        let shared = Arc::new(JobShared {
            owner: self.owner,
            id,
            document,
            state: Mutex::new(State {
                abort_requested: false,
                progress: AnalysisProgress {
                    phase: JobPhase::Queued,
                    cancellation_requested: false,
                    processed: AnalysisCounts {
                        pages_total: pages.len() as u64,
                        ..Default::default()
                    },
                    delivered: Default::default(),
                    input_bytes: 0,
                    pending_result_bytes: 0,
                    pending_updates: 0,
                    peak_input_bytes: 0,
                    peak_result_bytes: 0,
                    peak_pending_updates: 0,
                },
                queue: VecDeque::new(),
                request: None,
                reply: None,
                source_stop: false,
                source_done: false,
                processing_done: false,
                delivery_done: false,
                delivery_error: None,
                outcome: None,
            }),
            changed: Condvar::new(),
        });
        let mut queue = self.queue.lock();
        if queue.closed {
            return Err(queue
                .failure
                .clone()
                .unwrap_or_else(|| Error::input("analyzer is closed")));
        }
        if queue.queue.len() >= self.options.limits.queued_jobs() as usize {
            return Err(Error::new(
                ErrorCode::LimitExceeded,
                "analyzer job queue is full",
            ));
        }
        queue.queue.push_back(QueuedJob {
            shared: shared.clone(),
            pages,
            source: Box::new(source),
            sink: Box::new(sink),
            options,
        });
        self.queue.changed.notify_all();
        Ok(AnalysisJob { shared })
    }

    /// Analyze one lazily rendered page through the same scheduler and updates.
    /// Use `LayoutSession` for an already-rendered blocking single-page call.
    pub fn analyze_page<L, F>(
        &self,
        page: PageDescriptor,
        options: AnalysisOptions,
        loader: L,
        sink: F,
    ) -> Result<AnalysisJob>
    where
        L: FnOnce(PageRequest) -> Result<PageInput> + Send + 'static,
        F: FnMut(AnalysisUpdate) -> Result<()> + Send + 'static,
    {
        struct OnePage<L> {
            page: PageDescriptor,
            loader: Option<L>,
        }
        impl<L: FnOnce(PageRequest) -> Result<PageInput> + Send + 'static> PageSource for OnePage<L> {
            fn document(&self) -> &DocumentRef {
                &self.page.key.document
            }
            fn pages(&self) -> &[PageDescriptor] {
                std::slice::from_ref(&self.page)
            }
            fn load_page(&mut self, request: PageRequest) -> Result<PageInput> {
                self.loader
                    .take()
                    .ok_or_else(|| Error::new(ErrorCode::PageSource, "page already requested"))?(
                    request,
                )
            }
        }
        self.analyze_document(
            OnePage {
                page,
                loader: Some(loader),
            },
            options,
            sink,
        )
    }

    fn request_close(&self) {
        let mut queue = self.queue.lock();
        queue.closed = true;
        if let Some(active) = &queue.active {
            CancellationHandle {
                shared: active.clone(),
            }
            .cancel();
        }
        for job in &queue.queue {
            CancellationHandle {
                shared: job.shared.clone(),
            }
            .cancel();
        }
        self.queue.changed.notify_all();
    }
    /// Cancel owned jobs and join all work/callbacks. Concurrent closes wait for
    /// the same drain. A caller callback that never returns can delay this call.
    pub fn close(&self) -> Result<()> {
        self.request_close();
        reject_callback_wait(self.owner)?;
        let mut worker = self.worker.lock().unwrap_or_else(|p| p.into_inner());
        if let Some(worker) = worker.take() {
            worker
                .join()
                .map_err(|_| Error::new(ErrorCode::WorkerFailed, "analyzer scheduler panicked"))?;
        }
        Ok(())
    }
}
impl Drop for Analyzer {
    fn drop(&mut self) {
        let _ = self.close();
    }
}

thread_local! { static CALLBACK_OWNER:Cell<Option<u64>>=const { Cell::new(None) }; }
struct CallbackGuard(Option<u64>);
impl CallbackGuard {
    fn enter(owner: u64) -> Self {
        Self(CALLBACK_OWNER.with(|c| c.replace(Some(owner))))
    }
}
impl Drop for CallbackGuard {
    fn drop(&mut self) {
        CALLBACK_OWNER.with(|c| c.set(self.0));
    }
}
fn reject_callback_wait(owner: u64) -> Result<()> {
    if CALLBACK_OWNER.with(|c| c.get() == Some(owner)) {
        Err(Error::input(
            "source/sink callbacks cannot wait for or close their analyzer's jobs",
        ))
    } else {
        Ok(())
    }
}
