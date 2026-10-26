use super::*;
use crate::{
    FormulaScope, LayoutRegion, PageAnalysis, ResourceLimits,
    results::{Diagnostic, FormulaOutcome, FormulaState, UpdatePayload},
};
use std::{
    panic::{AssertUnwindSafe, catch_unwind},
    sync::atomic::{AtomicU64, Ordering},
};

pub(super) trait Pipeline: Send {
    fn capabilities(&self) -> Capabilities;
    fn layout(&mut self, input: &PageInput, options: &AnalysisOptions) -> Result<PageAnalysis>;
    fn recognize(
        &mut self,
        _input: &PageInput,
        _region: &LayoutRegion,
        _cancel: &CancellationHandle,
    ) -> Result<FormulaOutcome> {
        Err(Error::new(
            ErrorCode::UnsupportedCapability,
            "no formula recognizer loaded",
        ))
    }
    fn failed(&self) -> bool {
        false
    }
}
pub(super) struct LayoutPipeline {
    pub(super) session: crate::LayoutSession,
}
impl Pipeline for LayoutPipeline {
    fn capabilities(&self) -> Capabilities {
        self.session.capabilities()
    }
    fn layout(&mut self, input: &PageInput, options: &AnalysisOptions) -> Result<PageAnalysis> {
        self.session.analyze_page(input.clone(), options.clone())
    }
    fn failed(&self) -> bool {
        self.session.failed()
    }
}

impl Analyzer {
    pub(super) fn start(
        mut pipeline: Box<dyn Pipeline>,
        profile: String,
        options: AnalyzerOptions,
    ) -> Result<Self> {
        static NEXT_OWNER: AtomicU64 = AtomicU64::new(1);
        let owner = NEXT_OWNER
            .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |v| v.checked_add(1))
            .map_err(|_| {
                Error::new(
                    ErrorCode::LimitExceeded,
                    "analyzer identity space exhausted",
                )
            })?;
        let capabilities = pipeline.capabilities();
        let queue = Arc::new(QueueShared {
            state: Mutex::new(QueueState {
                closed: false,
                failure: None,
                queue: VecDeque::new(),
                active: None,
            }),
            changed: Condvar::new(),
        });
        let worker_queue = queue.clone();
        let limits = options.limits;
        let worker = std::thread::Builder::new()
            .name("podoco-jobs".into())
            .spawn(move || {
                loop {
                    let (job, failure) = {
                        let mut state = worker_queue.lock();
                        while state.queue.is_empty() && !state.closed {
                            state = worker_queue
                                .changed
                                .wait(state)
                                .unwrap_or_else(|p| p.into_inner());
                        }
                        let Some(job) = state.queue.pop_front() else {
                            break;
                        };
                        state.active = Some(job.shared.clone());
                        (job, state.failure.clone())
                    };
                    let shared = job.shared.clone();
                    let result = catch_unwind(AssertUnwindSafe(|| {
                        run_job(job, pipeline.as_mut(), limits, failure)
                    }));
                    let fatal = match result {
                        Ok(fatal) => fatal,
                        Err(_) => {
                            let error =
                                Error::new(ErrorCode::WorkerFailed, "document worker panicked");
                            finish(
                                &shared,
                                summary(&shared, CompletionStatus::Failed, Some(&error)),
                                Some(error.clone()),
                            );
                            Some(error)
                        }
                    };
                    let mut state = worker_queue.lock();
                    state.active = None;
                    if let Some(error) = fatal {
                        state.failure = Some(error);
                        state.closed = true;
                        for job in &state.queue {
                            CancellationHandle {
                                shared: job.shared.clone(),
                            }
                            .cancel();
                        }
                    }
                    worker_queue.changed.notify_all();
                }
                // Dropping the safe session joins its native owner thread.
            })
            .map_err(|e| Error::new(ErrorCode::WorkerFailed, e.to_string()))?;
        Ok(Self {
            owner,
            queue,
            worker: Mutex::new(Some(worker)),
            capabilities,
            profile,
            options,
        })
    }
}

fn cancelled() -> Error {
    Error::new(ErrorCode::Cancelled, "analysis cancelled")
}
fn callback_error(kind: &str, error: Error) -> Error {
    Error::new(
        if kind == "sink" {
            ErrorCode::Delivery
        } else {
            ErrorCode::PageSource
        },
        format!("{kind}: {error}"),
    )
}

fn source_loop(shared: Arc<JobShared>, mut source: Box<dyn PageSource>, limit: u64) {
    let _guard = CallbackGuard::enter(shared.owner);
    loop {
        let page = {
            let mut state = shared.lock();
            while state.request.is_none()
                && !state.source_stop
                && !state.abort_requested
                && !state.progress.cancellation_requested
            {
                state = shared.wait(state);
            }
            if state.source_stop || state.abort_requested || state.progress.cancellation_requested {
                state.source_done = true;
                shared.changed.notify_all();
                return;
            }
            state.request.take().expect("request checked")
        };
        let result = catch_unwind(AssertUnwindSafe(|| {
            if source.document() != &shared.document {
                return Err(Error::new(
                    ErrorCode::SourceChanged,
                    "source revision changed before rendering",
                ));
            }
            let result = source.load_page(PageRequest {
                page,
                requirements: RasterRequirements {
                    preferred_format: PixelFormat::Bgra8,
                    background_rgb: [255; 3],
                },
                byte_budget: limit,
                cancellation: CancellationHandle {
                    shared: shared.clone(),
                },
            });
            if source.document() != &shared.document {
                return Err(Error::new(
                    ErrorCode::SourceChanged,
                    "source revision changed during rendering",
                ));
            }
            result
        }))
        .unwrap_or_else(|_| Err(Error::new(ErrorCode::WorkerFailed, "page source panicked")));
        let mut state = shared.lock();
        if state.source_stop || state.abort_requested || state.progress.cancellation_requested {
            state.source_done = true;
            shared.changed.notify_all();
            drop(state);
            drop(result);
            return;
        }
        state.reply = Some(result);
        shared.changed.notify_all();
    }
}

fn release_queued(state: &mut State, all: bool) {
    let mut kept = VecDeque::new();
    while let Some(entry) = state.queue.pop_front() {
        if !all && entry.terminal {
            kept.push_back(entry);
        } else {
            state.progress.pending_result_bytes -= entry.bytes.capacity() as u64;
            state.progress.pending_updates -= 1;
        }
    }
    state.queue = kept;
}
fn delivery_loop(shared: Arc<JobShared>, mut sink: Sink, max_bytes: u64) {
    let _guard = CallbackGuard::enter(shared.owner);
    loop {
        let entry = {
            let mut state = shared.lock();
            if state.progress.cancellation_requested {
                release_queued(&mut state, false);
                shared.changed.notify_all();
            }
            while state.queue.is_empty() && !state.processing_done {
                state = shared.wait(state);
            }
            let Some(entry) = state.queue.pop_front() else {
                state.delivery_done = true;
                shared.changed.notify_all();
                return;
            };
            if state.progress.cancellation_requested && !entry.terminal {
                state.progress.pending_result_bytes -= entry.bytes.capacity() as u64;
                state.progress.pending_updates -= 1;
                shared.changed.notify_all();
                continue;
            }
            entry
        };
        let size = entry.bytes.capacity() as u64;
        let result = catch_unwind(AssertUnwindSafe(|| {
            let update =
                AnalysisUpdate::from_json(&entry.bytes, max_bytes.min(usize::MAX as u64) as usize)?;
            let sequence = update.sequence();
            let page = matches!(update.payload(), UpdatePayload::PageFinished { .. });
            let formula = matches!(update.payload(), UpdatePayload::FormulaFinished { .. });
            let terminal = entry.terminal;
            drop(entry);
            sink(update)?;
            Ok((sequence, page, formula, terminal))
        }))
        .unwrap_or_else(|_| Err(Error::new(ErrorCode::Delivery, "update sink panicked")));
        let mut state = shared.lock();
        state.progress.pending_result_bytes -= size;
        state.progress.pending_updates -= 1;
        match result {
            Ok((sequence, page, formula, terminal)) => {
                let delivered = &mut state.progress.delivered;
                delivered.updates_acknowledged += 1;
                delivered.last_sequence = Some(sequence);
                delivered.pages_finished += u64::from(page);
                delivered.formulas_finished += u64::from(formula);
                delivered.document_finished |= terminal;
            }
            Err(error) => {
                state.abort_requested = true;
                state.delivery_error = Some(callback_error("sink", error));
                release_queued(&mut state, true);
                state.delivery_done = true;
                shared.changed.notify_all();
                return;
            }
        }
        shared.changed.notify_all();
    }
}

fn emit(
    shared: &JobShared,
    limits: ResourceLimits,
    sequence: &mut u64,
    payload: UpdatePayload,
) -> Result<()> {
    let terminal = matches!(payload, UpdatePayload::DocumentFinished { .. });
    let update = AnalysisUpdate::new(
        shared.id.clone(),
        shared.document.clone(),
        *sequence,
        payload,
    )?;
    *sequence = sequence
        .checked_add(1)
        .ok_or_else(|| Error::new(ErrorCode::LimitExceeded, "update sequence exhausted"))?;
    // Reserve before encoding, so backpressure also bounds a producer's buffer.
    let reservation = limits.max_update_bytes();
    {
        let mut state = shared.lock();
        loop {
            if let Some(error) = &state.delivery_error {
                return Err(error.clone());
            }
            if !terminal && state.progress.cancellation_requested {
                return Err(cancelled());
            }
            if state.progress.pending_updates < limits.pending_updates()
                && reservation <= limits.result_bytes() - state.progress.pending_result_bytes
            {
                break;
            }
            state = shared.wait(state);
        }
        state.progress.pending_updates += 1;
        state.progress.pending_result_bytes += reservation;
        state.progress.peak_pending_updates = state
            .progress
            .peak_pending_updates
            .max(state.progress.pending_updates);
        state.progress.peak_result_bytes = state
            .progress
            .peak_result_bytes
            .max(state.progress.pending_result_bytes);
    }
    let encoded = update.to_json(reservation.min(usize::MAX as u64) as usize);
    let mut state = shared.lock();
    state.progress.pending_result_bytes -= reservation;
    state.progress.pending_updates -= 1;
    let result = (|| {
        let bytes = encoded?;
        if bytes.capacity() as u64 > reservation {
            return Err(Error::new(
                ErrorCode::LimitExceeded,
                "serialized allocation exceeds update reservation",
            ));
        }
        if let Some(error) = &state.delivery_error {
            return Err(error.clone());
        }
        if !terminal && state.progress.cancellation_requested {
            return Err(cancelled());
        }
        state.progress.pending_result_bytes += bytes.capacity() as u64;
        state.progress.pending_updates += 1;
        state.queue.push_back(EncodedUpdate { bytes, terminal });
        Ok(())
    })();
    shared.changed.notify_all();
    result
}

fn load(shared: &JobShared, page: &PageDescriptor, limit: u64) -> Result<PageInput> {
    let mut state = shared.lock();
    if state.progress.cancellation_requested {
        return Err(cancelled());
    }
    if let Some(error) = &state.delivery_error {
        return Err(error.clone());
    }
    state.progress.input_bytes = limit;
    state.progress.peak_input_bytes = state.progress.peak_input_bytes.max(limit);
    state.request = Some(page.clone());
    shared.changed.notify_all();
    while state.reply.is_none()
        && !state.source_done
        && !state.progress.cancellation_requested
        && state.delivery_error.is_none()
    {
        state = shared.wait(state);
    }
    if state.progress.cancellation_requested {
        return Err(cancelled());
    }
    if let Some(error) = &state.delivery_error {
        return Err(error.clone());
    }
    let reply = state
        .reply
        .take()
        .ok_or_else(|| Error::new(ErrorCode::WorkerFailed, "source worker stopped"))?;
    drop(state);
    let input = reply?;
    if input.descriptor().key.document != shared.document {
        return Err(Error::new(
            ErrorCode::SourceChanged,
            "rendered page belongs to a different revision",
        ));
    }
    if input.descriptor() != page {
        return Err(Error::new(
            ErrorCode::PageSource,
            "rendered page does not match its descriptor",
        ));
    }
    let bytes = input.image().retained_bytes() as u64;
    if bytes > limit {
        return Err(Error::new(
            ErrorCode::LimitExceeded,
            "source exceeded input reservation",
        ));
    }
    shared.lock().progress.input_bytes = bytes;
    Ok(input)
}

fn add(value: &mut u64, amount: u64) -> Result<()> {
    *value = value
        .checked_add(amount)
        .ok_or_else(|| Error::new(ErrorCode::LimitExceeded, "analysis counter overflow"))?;
    Ok(())
}
fn stop_reason(shared: &JobShared) -> Result<()> {
    let state = shared.lock();
    if let Some(error) = &state.delivery_error {
        Err(error.clone())
    } else if state.progress.cancellation_requested {
        Err(cancelled())
    } else {
        Ok(())
    }
}
fn process_pages(
    shared: &Arc<JobShared>,
    pages: &[PageDescriptor],
    options: &AnalysisOptions,
    pipeline: &mut dyn Pipeline,
    limits: ResourceLimits,
    sequence: &mut u64,
) -> Result<()> {
    for descriptor in pages {
        stop_reason(shared)?;
        let input = match load(shared, descriptor, limits.input_bytes()) {
            Ok(input) => input,
            Err(error) => {
                if matches!(
                    error.code,
                    ErrorCode::Cancelled
                        | ErrorCode::SourceChanged
                        | ErrorCode::WorkerFailed
                        | ErrorCode::Delivery
                ) {
                    // A cancelled renderer may still own pixels. Keep its
                    // reservation until stop_source has joined the callback.
                    return Err(error);
                }
                shared.lock().progress.input_bytes = 0;
                add(&mut shared.lock().progress.processed.pages_failed, 1)?;
                emit(
                    shared,
                    limits,
                    sequence,
                    UpdatePayload::PageFailed {
                        page_key: descriptor.key.clone(),
                        error,
                    },
                )?;
                continue;
            }
        };
        stop_reason(shared)?;
        let mut page = match pipeline.layout(&input, options) {
            Ok(page) => page,
            Err(error) => {
                drop(input);
                shared.lock().progress.input_bytes = 0;
                let fatal = pipeline.failed()
                    || matches!(error.code, ErrorCode::Backend | ErrorCode::WorkerFailed);
                add(&mut shared.lock().progress.processed.pages_failed, 1)?;
                let delivered = emit(
                    shared,
                    limits,
                    sequence,
                    UpdatePayload::PageFailed {
                        page_key: descriptor.key.clone(),
                        error: error.clone(),
                    },
                );
                if fatal {
                    // Preserve native failure even if cancellation or a sink
                    // failure prevents publishing this page's failure notice.
                    return Err(error);
                }
                delivered?;
                continue;
            }
        };
        if page.page != *descriptor
            || page.provenance.image != input.image().descriptor()
            || page.provenance.pixel_to_page != input.pixel_to_page()
            || &page.provenance.render_profile != input.render_profile()
        {
            return Err(Error::new(
                ErrorCode::InvalidResult,
                "pipeline changed page identity or raster provenance",
            ));
        }
        page.formula_scope = options.formula_scope;
        let all = options.formula_scope == FormulaScope::All;
        for formula in &mut page.formulas {
            formula.state = if all {
                FormulaState::Pending
            } else {
                FormulaState::NotRequested
            };
        }
        page.validate(false)?;
        {
            let mut state = shared.lock();
            let counts = &mut state.progress.processed;
            let n = page.formulas.len() as u64;
            add(&mut counts.formulas_detected, n)?;
            add(
                if all {
                    &mut counts.formulas_pending
                } else {
                    &mut counts.formulas_not_requested
                },
                n,
            )?;
        }
        if all {
            emit(
                shared,
                limits,
                sequence,
                UpdatePayload::PageLayoutReady {
                    page: Box::new(page.clone()),
                },
            )?;
            for i in 0..page.formulas.len() {
                stop_reason(shared)?;
                let id = page.formulas[i].region_id;
                let region = page
                    .regions
                    .iter()
                    .find(|r| r.id == id)
                    .expect("validated formula region");
                let outcome = match pipeline.recognize(
                    &input,
                    region,
                    &CancellationHandle {
                        shared: shared.clone(),
                    },
                ) {
                    Ok(outcome) => outcome,
                    Err(error)
                        if pipeline.failed()
                            || matches!(
                                error.code,
                                ErrorCode::Backend | ErrorCode::WorkerFailed | ErrorCode::Cancelled
                            ) =>
                    {
                        return Err(error);
                    }
                    Err(error) => FormulaOutcome::Failed { error },
                };
                page.formulas[i].state = FormulaState::Finished {
                    outcome: outcome.clone(),
                };
                page.validate(false)?;
                {
                    let mut state = shared.lock();
                    let counts = &mut state.progress.processed;
                    counts.formulas_pending -= 1;
                    add(
                        match &outcome {
                            FormulaOutcome::Recognized { .. } => &mut counts.formulas_recognized,
                            FormulaOutcome::Failed { .. } => &mut counts.formulas_failed,
                            FormulaOutcome::Truncated { .. } => &mut counts.formulas_truncated,
                        },
                        1,
                    )?;
                }
                emit(
                    shared,
                    limits,
                    sequence,
                    UpdatePayload::FormulaFinished {
                        page_key: page.page.key.clone(),
                        region_id: id,
                        outcome,
                    },
                )?;
            }
        }
        // Layout-only results never retain the image while awaiting the sink.
        drop(input);
        {
            let mut state = shared.lock();
            state.progress.input_bytes = 0;
            add(&mut state.progress.processed.pages_finished, 1)?;
            shared.changed.notify_all();
        }
        if !all {
            emit(
                shared,
                limits,
                sequence,
                UpdatePayload::PageLayoutReady {
                    page: Box::new(page.clone()),
                },
            )?;
        }
        emit(
            shared,
            limits,
            sequence,
            UpdatePayload::PageFinished {
                page: Box::new(page),
            },
        )?;
    }
    Ok(())
}

struct Pumps {
    shared: Arc<JobShared>,
    source: Option<JoinHandle<()>>,
    delivery: Option<JoinHandle<()>>,
}
impl Pumps {
    fn stop_source(&mut self) -> Result<()> {
        let reply = {
            let mut state = self.shared.lock();
            state.source_stop = true;
            state.request.take();
            self.shared.changed.notify_all();
            state.reply.take()
        };
        drop(reply);
        let result = self
            .source
            .take()
            .map(|t| t.join())
            .transpose()
            .map_err(|_| {
                Error::new(
                    ErrorCode::WorkerFailed,
                    "source worker panicked during shutdown",
                )
            });
        let reply = {
            let mut state = self.shared.lock();
            state.progress.input_bytes = 0;
            state.reply.take()
        };
        drop(reply);
        result.map(|_| ())
    }
    fn stop_delivery(&mut self) -> Result<()> {
        {
            let mut state = self.shared.lock();
            state.processing_done = true;
            self.shared.changed.notify_all();
        }
        self.delivery
            .take()
            .map(|t| t.join())
            .transpose()
            .map_err(|_| Error::new(ErrorCode::Delivery, "sink worker panicked during shutdown"))?;
        Ok(())
    }
}
impl Drop for Pumps {
    fn drop(&mut self) {
        if self.source.is_none() && self.delivery.is_none() {
            return;
        }
        CancellationHandle {
            shared: self.shared.clone(),
        }
        .cancel();
        {
            let mut state = self.shared.lock();
            release_queued(&mut state, true);
        }
        let _ = self.stop_source();
        let _ = self.stop_delivery();
    }
}

fn run_job(
    job: QueuedJob,
    pipeline: &mut dyn Pipeline,
    limits: ResourceLimits,
    prior_failure: Option<Error>,
) -> Option<Error> {
    let QueuedJob {
        shared,
        pages,
        source,
        sink,
        options,
    } = job;
    shared.lock().progress.phase = JobPhase::Running;
    let mut pumps = Pumps {
        shared: shared.clone(),
        source: None,
        delivery: None,
    };
    let source_shared = shared.clone();
    let source = std::thread::Builder::new()
        .name("podoco-source".into())
        .spawn(move || source_loop(source_shared, source, limits.input_bytes()));
    let mut error = prior_failure;
    match source {
        Ok(handle) => pumps.source = Some(handle),
        Err(e) => error = Some(Error::new(ErrorCode::WorkerFailed, e.to_string())),
    }
    let delivery_shared = shared.clone();
    match std::thread::Builder::new()
        .name("podoco-delivery".into())
        .spawn(move || delivery_loop(delivery_shared, sink, limits.max_update_bytes()))
    {
        Ok(handle) => pumps.delivery = Some(handle),
        Err(e) => {
            let e = Error::new(ErrorCode::Delivery, e.to_string());
            shared.lock().delivery_error = Some(e.clone());
            error = Some(e);
        }
    }
    let mut sequence = 0;
    let mut panicked = false;
    if error.is_none() {
        match catch_unwind(AssertUnwindSafe(|| {
            process_pages(&shared, &pages, &options, pipeline, limits, &mut sequence)
        })) {
            Ok(result) => error = result.err(),
            Err(_) => {
                panicked = true;
                error = Some(Error::new(
                    ErrorCode::WorkerFailed,
                    "document pipeline panicked",
                ));
            }
        }
    }
    if error.is_some() {
        let mut state = shared.lock();
        state.abort_requested = true;
        shared.changed.notify_all();
    }
    if let Err(e) = pumps.stop_source() {
        error.get_or_insert(e);
    }
    let fatal = (panicked
        || pipeline.failed()
        || error.as_ref().is_some_and(|e| e.code == ErrorCode::Backend))
    .then(|| {
        error
            .clone()
            .unwrap_or_else(|| Error::new(ErrorCode::Backend, "native pipeline terminated"))
    });
    shared.lock().progress.phase = JobPhase::Finishing;
    let counts = shared.lock().progress.processed;
    let status = if error
        .as_ref()
        .is_some_and(|e| e.code != ErrorCode::Cancelled)
    {
        CompletionStatus::Failed
    } else if shared.cancelled()
        || error
            .as_ref()
            .is_some_and(|e| e.code == ErrorCode::Cancelled)
    {
        CompletionStatus::Cancelled
    } else if counts.pages_failed > 0 || counts.formulas_failed > 0 || counts.formulas_truncated > 0
    {
        CompletionStatus::Partial
    } else {
        CompletionStatus::Completed
    };
    let summary = summary(&shared, status, error.as_ref());
    // Do not hold a temporary state guard while emit waits on the same mutex.
    let can_deliver = shared.lock().delivery_error.is_none();
    if can_deliver
        && let Err(e) = emit(
            &shared,
            limits,
            &mut sequence,
            UpdatePayload::DocumentFinished {
                summary: summary.clone(),
            },
        )
    {
        shared.lock().delivery_error = Some(e.clone());
        error = Some(e);
    }
    if let Err(e) = pumps.stop_delivery() {
        shared.lock().delivery_error = Some(e.clone());
        error = Some(e);
    }
    finish(&shared, summary, error);
    fatal
}
fn summary(shared: &JobShared, status: CompletionStatus, error: Option<&Error>) -> AnalysisSummary {
    AnalysisSummary {
        status,
        counts: shared.lock().progress.processed,
        diagnostics: error
            .filter(|e| e.code != ErrorCode::Cancelled)
            .map(|e| Diagnostic {
                code: crate::ProfileId::new("job-failure-v1").expect("literal"),
                message: e.to_string(),
            })
            .into_iter()
            .collect(),
    }
}
fn finish(shared: &JobShared, summary: AnalysisSummary, error: Option<Error>) {
    let mut state = shared.lock();
    if state.outcome.is_some() {
        return;
    }
    let error = state
        .delivery_error
        .clone()
        .or(error)
        .filter(|e| e.code != ErrorCode::Cancelled);
    let status = if error.is_some() {
        CompletionStatus::Failed
    } else if state.progress.cancellation_requested {
        CompletionStatus::Cancelled
    } else {
        summary.status
    };
    release_queued(&mut state, true);
    state.progress.pending_result_bytes = 0;
    state.progress.pending_updates = 0;
    state.progress.phase = JobPhase::Finished;
    state.progress.input_bytes = 0;
    state.outcome = Some(AnalysisOutcome {
        status,
        summary,
        delivered: state.progress.delivered,
        error,
        progress: state.progress.clone(),
    });
    shared.changed.notify_all();
}
