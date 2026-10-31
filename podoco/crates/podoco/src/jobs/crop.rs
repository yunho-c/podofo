//! Explicit recognition shares admission and native sessions with document jobs.
use super::*;
use crate::{
    Rect, RegionId, ResourceLimits,
    formula::{FormulaCancellation, FormulaInput},
    results::{FormulaDisplayKind, FormulaOutcome},
};
use serde::Deserialize;
use std::panic::{AssertUnwindSafe, catch_unwind};

/// Caller-supplied formula identity and canonical geometry, without a detection.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct FormulaCrop {
    /// Owning page and revision, even when the raster contains only this crop.
    pub page: PageDescriptor,
    /// Stable local region identity for applying the outcome.
    pub region_id: RegionId,
    /// Formula bounds in canonical displayed page coordinates.
    pub bounds: Rect,
    /// Caller-supplied context; never inferred from raster dimensions.
    pub display_kind: FormulaDisplayKind,
}
impl FormulaCrop {
    fn validate(&self) -> Result<()> {
        let [l, t, r, b] = self.bounds.edges();
        if l < 0. || t < 0. || r > self.page.space.width() || b > self.page.space.height() {
            return Err(Error::input(
                "formula bounds must lie within the owning page",
            ));
        }
        Ok(())
    }
}

/// Lazy image request after the shared inference lane reserves input capacity.
#[derive(Clone)]
pub struct FormulaRequest {
    /// Exact snapshotted formula identity and geometry.
    pub crop: FormulaCrop,
    /// Preferred pixel format and background; original resolution is preserved.
    pub requirements: RasterRequirements,
    /// Maximum retained image allocation including padding/trailing bytes.
    pub byte_budget: u64,
    /// Cooperative signal, also used between native decoder calls.
    pub cancellation: FormulaCancellation,
}

/// Coalesced lifecycle for a single explicit crop, without synthetic page counts.
#[derive(Clone, Debug, Serialize)]
pub struct FormulaJobProgress {
    /// Queue, running, draining, or finished state.
    pub phase: JobPhase,
    /// User cancellation or analyzer shutdown requested a stop.
    pub cancellation_requested: bool,
    /// Input reservation or retained allocation; zero after source/native drain.
    pub input_bytes: u64,
    /// Largest input reservation, excluding caller-owned captures before rendering.
    pub peak_input_bytes: u64,
    /// Largest bounded serialized formula result. Excludes fixed job metadata.
    pub peak_result_bytes: u64,
}

/// Immutable completion with the supplied identity and the ordinary formula outcome.
#[derive(Clone, Debug, Serialize)]
pub struct FormulaJobOutcome {
    /// Unique invocation identity, including retries.
    pub analysis_id: AnalysisId,
    /// Caller-supplied page/region context, unchanged by recognition.
    pub crop: FormulaCrop,
    /// Completed/partial recognition, cancellation, or a source/backend failure.
    pub status: CompletionStatus,
    /// Recognized, failed, or truncated result; absent when work could not finish.
    pub outcome: Option<FormulaOutcome>,
    /// Fatal source/backend/worker error. Recognition failures live in `outcome`.
    pub error: Option<Error>,
    /// Final observations after all image readers and loader code have drained.
    pub progress: FormulaJobProgress,
}

struct State {
    phase: JobPhase,
    input_bytes: u64,
    peak_input_bytes: u64,
    peak_result_bytes: u64,
    outcome: Option<FormulaJobOutcome>,
}
pub(super) struct Shared {
    owner: u64,
    id: AnalysisId,
    crop: FormulaCrop,
    cancellation: FormulaCancellation,
    state: Mutex<State>,
    changed: Condvar,
}
impl Shared {
    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|p| p.into_inner())
    }
    pub(super) fn cancel(&self) {
        if self.lock().outcome.is_none() {
            self.cancellation.cancel();
        }
    }
    fn progress(&self, state: &State) -> FormulaJobProgress {
        FormulaJobProgress {
            phase: state.phase,
            cancellation_requested: self.cancellation.is_cancelled(),
            input_bytes: state.input_bytes,
            peak_input_bytes: state.peak_input_bytes,
            peak_result_bytes: state.peak_result_bytes,
        }
    }
    pub(super) fn finish(&self, mut outcome: Option<FormulaOutcome>, error: Option<Error>) {
        let mut state = self.lock();
        if state.outcome.is_some() {
            return;
        }
        let cancelled = self.cancellation.is_cancelled()
            || error
                .as_ref()
                .is_some_and(|e| e.code == ErrorCode::Cancelled);
        let error = error.filter(|e| e.code != ErrorCode::Cancelled);
        let status = if error.is_some() {
            CompletionStatus::Failed
        } else if cancelled {
            outcome = None;
            CompletionStatus::Cancelled
        } else if matches!(outcome, Some(FormulaOutcome::Recognized { .. })) {
            CompletionStatus::Completed
        } else {
            CompletionStatus::Partial
        };
        state.phase = JobPhase::Finished;
        state.input_bytes = 0;
        state.outcome = Some(FormulaJobOutcome {
            analysis_id: self.id.clone(),
            crop: self.crop.clone(),
            status,
            outcome,
            error,
            progress: self.progress(&state),
        });
        self.changed.notify_all();
    }
}

/// Eager explicit-crop work. Drop cancels and drains; prefer explicit close.
/// Loader callbacks may cancel but cannot wait for their analyzer's jobs.
pub struct FormulaJob {
    shared: Arc<Shared>,
}
impl FormulaJob {
    /// Unique invocation identity.
    pub fn id(&self) -> &AnalysisId {
        &self.shared.id
    }
    /// Independent cooperative control, with no native model objects.
    pub fn cancellation(&self) -> FormulaCancellation {
        self.shared.cancellation.clone()
    }
    /// Nonblocking idempotent cancellation request.
    pub fn cancel(&self) {
        self.shared.cancel();
    }
    /// Latest lifecycle; reading it does not start inference or consume output.
    pub fn progress(&self) -> FormulaJobProgress {
        let state = self.shared.lock();
        state
            .outcome
            .as_ref()
            .map_or_else(|| self.shared.progress(&state), |o| o.progress.clone())
    }
    /// Nonblocking authoritative outcome once native readers and the loader drain.
    pub fn try_outcome(&self) -> Option<FormulaJobOutcome> {
        self.shared.lock().outcome.clone()
    }
    /// Wait for the immutable outcome. Caller code that ignores cancellation can delay this.
    pub fn wait(&self) -> Result<FormulaJobOutcome> {
        reject_callback_wait(self.shared.owner)?;
        let mut state = self.shared.lock();
        while state.outcome.is_none() {
            state = self
                .shared
                .changed
                .wait(state)
                .unwrap_or_else(|p| p.into_inner());
        }
        Ok(state.outcome.as_ref().expect("outcome checked").clone())
    }
    /// Cancel unfinished work and wait for release/drain. Processing errors are in `wait`.
    pub fn close(&self) -> Result<()> {
        self.cancel();
        self.wait().map(|_| ())
    }
}
impl Drop for FormulaJob {
    fn drop(&mut self) {
        let _ = self.close();
    }
}

pub(super) struct QueuedFormula {
    pub(super) shared: Arc<Shared>,
    loader: Box<dyn FnOnce(FormulaRequest) -> Result<PageInput> + Send>,
    drain: Box<dyn FnOnce() -> Result<()> + Send>,
}
impl Analyzer {
    /// Recognize an explicitly identified crop without running layout detection.
    /// Shares FIFO admission, limits, persistent models and shutdown with document jobs.
    /// The loader runs only after admission and an input reservation. A cropped
    /// raster must retain its owning page descriptor and map pixel edges to page
    /// coordinates; a full-page raster with the same crop bounds is also accepted.
    pub fn recognize_formula<L>(&self, crop: FormulaCrop, loader: L) -> Result<FormulaJob>
    where
        L: FnOnce(FormulaRequest) -> Result<PageInput> + Send + 'static,
    {
        self.recognize_formula_with_drain(crop, loader, || Ok(()))
    }

    /// Explicit-crop submission with an asynchronous-owner release barrier.
    /// Foreign-runtime adapters use `drain` to consume deferred image-release
    /// acknowledgements before the next queued job can render. It runs once after
    /// the loader/native readers stop, including failure/cancellation, without
    /// locks held. It may cancel but cannot wait/close this analyzer's jobs.
    /// Ordinary Rust callers should use `recognize_formula`.
    pub fn recognize_formula_with_drain<L, D>(
        &self,
        crop: FormulaCrop,
        loader: L,
        drain: D,
    ) -> Result<FormulaJob>
    where
        L: FnOnce(FormulaRequest) -> Result<PageInput> + Send + 'static,
        D: FnOnce() -> Result<()> + Send + 'static,
    {
        if !self.capabilities.formula_recognition {
            return Err(Error::new(
                ErrorCode::UnsupportedCapability,
                "no formula recognizer loaded",
            ));
        }
        crop.validate()?;
        let mut random = [0u8; 16];
        getrandom::fill(&mut random)
            .map_err(|e| Error::new(ErrorCode::WorkerFailed, format!("formula ID: {e}")))?;
        let shared = Arc::new(Shared {
            owner: self.owner,
            id: AnalysisId::new(format!("podoco-{:032x}", u128::from_le_bytes(random)))?,
            crop,
            cancellation: FormulaCancellation::default(),
            state: Mutex::new(State {
                phase: JobPhase::Queued,
                input_bytes: 0,
                peak_input_bytes: 0,
                peak_result_bytes: 0,
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
        queue.queue.push_back(QueuedJob::Formula(QueuedFormula {
            shared: shared.clone(),
            loader: Box::new(loader),
            drain: Box::new(drain),
        }));
        self.queue.changed.notify_all();
        Ok(FormulaJob { shared })
    }
}

pub(super) fn run(
    job: QueuedFormula,
    pipeline: &mut dyn engine::Pipeline,
    limits: ResourceLimits,
    prior_failure: Option<Error>,
) -> Option<Error> {
    let QueuedFormula {
        shared,
        loader,
        drain,
    } = job;
    if let Some(error) = prior_failure {
        drop(loader);
        complete(&shared, None, Some(error), drain);
        return None;
    }
    if shared.cancellation.is_cancelled() {
        drop(loader);
        complete(&shared, None, None, drain);
        return None;
    }
    {
        let mut state = shared.lock();
        state.phase = JobPhase::Running;
        state.input_bytes = limits.input_bytes();
        state.peak_input_bytes = limits.input_bytes();
    }
    // Loading runs on the scheduler worker before native prediction. A polled
    // foreign render must reply even after cancellation; transport owns that rendezvous.
    let input = {
        let _guard = CallbackGuard::enter(shared.owner);
        catch_unwind(AssertUnwindSafe(|| {
            loader(FormulaRequest {
                crop: shared.crop.clone(),
                requirements: RasterRequirements {
                    preferred_format: PixelFormat::Bgra8,
                    background_rgb: [255; 3],
                },
                byte_budget: limits.input_bytes(),
                cancellation: shared.cancellation.clone(),
            })
        }))
        .unwrap_or_else(|_| Err(Error::new(ErrorCode::PageSource, "formula loader panicked")))
    };
    let result = catch_unwind(AssertUnwindSafe(|| {
        input.and_then(|page| {
            if shared.cancellation.is_cancelled() {
                return Err(Error::new(ErrorCode::Cancelled, "formula cancelled"));
            }
            if page.descriptor() != &shared.crop.page {
                return Err(Error::new(
                    ErrorCode::SourceChanged,
                    "formula image differs from its page/revision descriptor",
                ));
            }
            let bytes = page.image().retained_bytes() as u64;
            if bytes > limits.input_bytes() {
                return Err(Error::new(
                    ErrorCode::LimitExceeded,
                    "formula image exceeds input reservation",
                ));
            }
            let [l, t, r, b] = page
                .pixel_to_page()
                .inverse()?
                .map_rect(shared.crop.bounds)?
                .edges();
            let dimensions = page.image().descriptor();
            // Permit only floating-point edge roundoff; never silently recognize a
            // clipped caller-supplied region. This is one ten-millionth of a pixel.
            const EDGE_EPSILON: f64 = 1e-7;
            if l < -EDGE_EPSILON
                || t < -EDGE_EPSILON
                || r > f64::from(dimensions.width()) + EDGE_EPSILON
                || b > f64::from(dimensions.height()) + EDGE_EPSILON
            {
                return Err(Error::input(
                    "formula image does not cover the supplied region",
                ));
            }
            shared.lock().input_bytes = bytes;
            let input = FormulaInput {
                page,
                region_id: shared.crop.region_id,
                bounds: shared.crop.bounds,
                display_kind: shared.crop.display_kind,
            };
            let outcome = match pipeline.recognize_crop(input, shared.cancellation.clone()) {
                Ok(outcome) => outcome,
                Err(error)
                    if !matches!(
                        error.code,
                        ErrorCode::Cancelled | ErrorCode::Backend | ErrorCode::WorkerFailed
                    ) =>
                {
                    FormulaOutcome::Failed { error }
                }
                Err(error) => return Err(error),
            };
            if let FormulaOutcome::Recognized { formula } = &outcome
                && formula.display_kind != shared.crop.display_kind
            {
                return Err(Error::new(
                    ErrorCode::InvalidResult,
                    "recognizer changed the supplied formula context",
                ));
            }
            let bytes =
                outcome.to_json(limits.max_update_bytes().min(usize::MAX as u64) as usize)?;
            shared.lock().peak_result_bytes = bytes.capacity() as u64;
            Ok(outcome)
        })
    }))
    .unwrap_or_else(|_| {
        Err(Error::new(
            ErrorCode::WorkerFailed,
            "formula pipeline panicked",
        ))
    });
    let (outcome, error) = match result {
        Ok(v) => (Some(v), None),
        Err(e) => (None, Some(e)),
    };
    let fatal = (pipeline.failed()
        || error
            .as_ref()
            .is_some_and(|e| matches!(e.code, ErrorCode::Backend | ErrorCode::WorkerFailed)))
    .then(|| {
        error
            .clone()
            .unwrap_or_else(|| Error::new(ErrorCode::Backend, "native formula pipeline terminated"))
    });
    complete(&shared, outcome, error, drain);
    fatal
}

fn complete(
    shared: &Shared,
    outcome: Option<FormulaOutcome>,
    error: Option<Error>,
    drain: Box<dyn FnOnce() -> Result<()> + Send>,
) {
    shared.lock().phase = JobPhase::Finishing;
    // Keep the reservation until the foreign release acknowledgement is consumed.
    let result = {
        let _guard = CallbackGuard::enter(shared.owner);
        catch_unwind(AssertUnwindSafe(drain)).unwrap_or_else(|_| {
            Err(Error::new(
                ErrorCode::Delivery,
                "formula drain callback panicked",
            ))
        })
    };
    let error = result
        .err()
        .map(|e| Error::new(ErrorCode::Delivery, format!("formula drain: {e}")))
        .or(error);
    shared.finish(outcome, error);
}
