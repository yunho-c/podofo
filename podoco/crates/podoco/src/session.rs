//! Reusable blocking page-layout sessions. Call these APIs off UI/executor threads.
use crate::{
    AnalysisOptions, AnalyzerOptions, Capabilities, Error, ErrorCode, ModelBundle, PageAnalysis,
    PageInput, Result,
};
use serde::Serialize;
use std::{
    sync::mpsc::{self, SyncSender},
    thread::JoinHandle,
    time::Instant,
};

/// Latest completed stage durations, measured with a monotonic clock.
#[derive(Clone, Copy, Debug, Default, Serialize)]
pub struct LayoutTimings {
    /// Source pixels to RGB NCHW tensor.
    pub preprocessing_seconds: f64,
    /// Native input write, prediction, output checks and small-output readback.
    pub prediction_seconds: f64,
    /// Layout decoding and page validation.
    pub decoding_seconds: f64,
    /// Caller-observed blocking request, including result-budget validation.
    pub total_seconds: f64,
}
/// Session-local observations. Memory is SDK-visible storage, not process RSS or
/// a limit on opaque Core ML weights, workspace, caches, or device allocations.
#[derive(Clone, Copy, Debug, Default, Serialize)]
pub struct LayoutSessionStats {
    /// Successful native model loads; one per open session.
    pub model_loads: u64,
    /// Native prediction attempts.
    pub predictions: u64,
    /// Reused preprocessing and small-output storage in bytes.
    pub host_buffer_bytes: u64,
    /// Peak accounted native tensor spans plus host buffers and a reserved 128 KiB scratch allowance.
    pub peak_tensor_bytes: u64,
    /// Blocking open time, excluding earlier bundle verification.
    pub open_seconds: f64,
    /// Most recent worker request; stages not reached remain zero. Requests
    /// rejected before reaching the worker leave these observations unchanged.
    pub last_timings: LayoutTimings,
}
#[cfg_attr(not(feature = "coreml"), allow(dead_code))]
enum Request {
    Analyze(
        PageInput,
        SyncSender<(Result<PageAnalysis>, LayoutSessionStats, bool)>,
    ),
}

/// A non-cloneable session with one worker owning all native state. Mutable
/// access serializes requests. Invalid inputs are recoverable; native failures
/// terminate the worker. Drop waits for release, as does explicit `close`.
pub struct LayoutSession {
    sender: Option<SyncSender<Request>>,
    worker: Option<JoinHandle<()>>,
    options: AnalyzerOptions,
    profile: String,
    capabilities: Capabilities,
    stats: LayoutSessionStats,
    failed: bool,
}
impl LayoutSession {
    pub(crate) fn failed(&self) -> bool {
        self.failed
    }
    /// Verify runtime support, load the model, and validate its native interface.
    /// The bundle payload must remain immutable for the session's lifetime.
    pub fn open(bundle: ModelBundle, options: AnalyzerOptions) -> Result<Self> {
        #[cfg(not(feature = "coreml"))]
        {
            let _ = (bundle, options);
            Err(Error::new(
                ErrorCode::UnsupportedCapability,
                "build Podoco with coreml to open a layout session",
            ))
        }
        #[cfg(feature = "coreml")]
        {
            use crate::pipelines::layout::{MIN_TENSOR_BYTES, PROFILE};
            if bundle.manifest().profile.id != PROFILE {
                return Err(Error::new(
                    ErrorCode::UnsupportedCapability,
                    "the v0 profile is reference-only; prepare the v1 runtime bundle",
                ));
            }
            if options.limits.tensor_bytes() < MIN_TENSOR_BYTES {
                return Err(Error::new(
                    ErrorCode::LimitExceeded,
                    format!("layout requires at least {MIN_TENSOR_BYTES} tensor bytes"),
                ));
            }
            let start = Instant::now();
            let (sender, receiver) = mpsc::sync_channel(1);
            let (ready, opened) = mpsc::sync_channel(1);
            let capabilities = bundle.declared_capabilities();
            let profile = bundle.manifest().profile.id.clone();
            let worker_options = options.clone();
            let worker = std::thread::Builder::new()
                .name("podoco-layout".into())
                .spawn(move || {
                    crate::runtime::coreml::pool(|| {
                        let mut pipeline = match crate::pipelines::layout::Pipeline::open(
                            &bundle,
                            &worker_options,
                        ) {
                            Ok(p) => p,
                            Err(e) => {
                                let _ = ready.send(Err(e));
                                return;
                            }
                        };
                        let mut stats = pipeline.initial_stats();
                        if ready.send(Ok(stats)).is_err() {
                            return;
                        }
                        while let Ok(Request::Analyze(input, reply)) = receiver.recv() {
                            stats.last_timings = LayoutTimings::default();
                            let result = pipeline.analyze(&input, &mut stats).and_then(|page| {
                                // Check bounded serialization before publishing the owned snapshot.
                                page.to_json(
                                    worker_options
                                        .limits
                                        .max_update_bytes()
                                        .min(usize::MAX as u64)
                                        as usize,
                                )?;
                                Ok(page)
                            });
                            let fatal = pipeline.failed;
                            drop(input);
                            if reply.send((result, stats, fatal)).is_err() || fatal {
                                break;
                            }
                        }
                        // Pipeline is dropped on its owner thread inside this pool.
                    });
                })
                .map_err(|e| Error::new(ErrorCode::WorkerFailed, e.to_string()))?;
            match opened.recv() {
                Ok(Ok(stats)) => Ok(Self {
                    sender: Some(sender),
                    worker: Some(worker),
                    options,
                    profile,
                    capabilities,
                    stats: LayoutSessionStats {
                        open_seconds: start.elapsed().as_secs_f64(),
                        ..stats
                    },
                    failed: false,
                }),
                result => {
                    let _ = worker.join();
                    Err(result
                        .ok()
                        .and_then(|r| r.err())
                        .unwrap_or_else(worker_failed))
                }
            }
        }
    }
    /// Loaded runtime functionality; formula recognition and polygons are absent.
    pub fn capabilities(&self) -> Capabilities {
        self.capabilities
    }

    /// Analyze a single owned page. Requires the bundle's exact profile and an
    /// explicit `FormulaScope::None`. Results do not retain the source image.
    pub fn analyze_page(
        &mut self,
        input: PageInput,
        options: AnalysisOptions,
    ) -> Result<PageAnalysis> {
        let start = Instant::now();
        if self.failed {
            return Err(worker_failed());
        }
        let sender = self
            .sender
            .as_ref()
            .ok_or_else(|| Error::input("layout session is closed"))?;
        if options.profile.as_str() != self.profile {
            return Err(Error::input("analysis profile does not match session"));
        }
        self.capabilities.validate(&options)?;
        if input.image().retained_bytes() as u64 > self.options.limits.input_bytes() {
            return Err(Error::new(
                ErrorCode::LimitExceeded,
                "page exceeds session input budget",
            ));
        }
        let (reply, receiver) = mpsc::sync_channel(1);
        if sender.send(Request::Analyze(input, reply)).is_err() {
            self.failed = true;
            return Err(worker_failed());
        }
        let (result, mut stats, fatal) = receiver.recv().map_err(|_| {
            self.failed = true;
            worker_failed()
        })?;
        stats.open_seconds = self.stats.open_seconds;
        stats.last_timings.total_seconds = start.elapsed().as_secs_f64();
        self.stats = stats;
        self.failed = fatal;
        result
    }
    /// Snapshot of counters and measured durations; no native pointers.
    pub fn stats(&self) -> LayoutSessionStats {
        self.stats
    }

    /// Stop accepting pages and wait for owner-thread release. Repeated calls
    /// succeed after successful cleanup. An unexpected worker panic is reported.
    pub fn close(&mut self) -> Result<()> {
        self.sender.take();
        if self
            .worker
            .take()
            .is_some_and(|worker| worker.join().is_err())
        {
            self.failed = true;
            return Err(worker_failed());
        }
        Ok(())
    }
}
fn worker_failed() -> Error {
    Error::new(ErrorCode::WorkerFailed, "layout worker terminated")
}
impl Drop for LayoutSession {
    fn drop(&mut self) {
        let _ = self.close();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        Affine, AlphaMode, DocumentRef, FormulaScope, ImageDescriptor, PageDescriptor, PageImage,
        PageKey, PageSpace, PixelFormat, ProfileId, ResourceLimits, options::ComputePolicy,
    };

    fn page() -> PageInput {
        PageInput::new(
            PageDescriptor {
                key: PageKey {
                    document: DocumentRef::new("test", "1").unwrap(),
                    page_index: 0,
                },
                space: PageSpace::new(1., 1.).unwrap(),
            },
            PageImage::copy(
                ImageDescriptor::new(1, 1, 4, PixelFormat::Rgba8, AlphaMode::Opaque).unwrap(),
                &[255; 4],
                4,
            )
            .unwrap(),
            Affine::new([1., 0., 0., 1., 0., 0.]).unwrap(),
            ProfileId::new("test").unwrap(),
        )
        .unwrap()
    }
    fn options() -> AnalyzerOptions {
        AnalyzerOptions {
            compute_policy: ComputePolicy::CpuOnly,
            limits: ResourceLimits::new(1, 4, 1, 2_000_000, 2_000_000, 96_000_000, 1).unwrap(),
        }
    }
    fn request() -> AnalysisOptions {
        let mut r =
            AnalysisOptions::new(ProfileId::new(crate::pipelines::layout::PROFILE).unwrap());
        r.formula_scope = FormulaScope::None;
        r
    }
    fn fake(worker: impl FnOnce(mpsc::Receiver<Request>) + Send + 'static) -> LayoutSession {
        let (sender, receiver) = mpsc::sync_channel(1);
        LayoutSession {
            sender: Some(sender),
            worker: Some(std::thread::spawn(move || worker(receiver))),
            options: options(),
            profile: crate::pipelines::layout::PROFILE.into(),
            capabilities: Capabilities {
                layout: true,
                formula_recognition: false,
                polygons: false,
                reading_order: true,
            },
            stats: Default::default(),
            failed: false,
        }
    }
    #[test]
    fn rejected_options_do_not_reach_worker_and_close_is_idempotent() {
        let mut session = fake(|receiver| assert!(receiver.recv().is_err()));
        let mut all = request();
        all.formula_scope = FormulaScope::All;
        assert_eq!(
            session.analyze_page(page(), all).unwrap_err().code,
            ErrorCode::UnsupportedCapability
        );
        let mut wrong = request();
        wrong.profile = ProfileId::new("wrong").unwrap();
        assert_eq!(
            session.analyze_page(page(), wrong).unwrap_err().code,
            ErrorCode::InvalidInput
        );
        session.options.limits = ResourceLimits::new(1, 1, 1, 1, 1, 1, 1).unwrap();
        assert_eq!(
            session.analyze_page(page(), request()).unwrap_err().code,
            ErrorCode::LimitExceeded
        );
        session.close().unwrap();
        session.close().unwrap();
        assert_eq!(
            session.analyze_page(page(), request()).unwrap_err().code,
            ErrorCode::InvalidInput
        );
    }
    #[test]
    fn recoverable_page_error_keeps_worker_usable() {
        let mut session = fake(|receiver| {
            for _ in 0..2 {
                let Request::Analyze(_page, reply) = receiver.recv().unwrap();
                reply
                    .send((Err(Error::input("bad page")), Default::default(), false))
                    .unwrap();
            }
        });
        for _ in 0..2 {
            assert_eq!(
                session.analyze_page(page(), request()).unwrap_err().code,
                ErrorCode::InvalidInput
            );
        }
        session.close().unwrap();
    }
    #[test]
    fn worker_panic_unblocks_reply_and_close_joins() {
        let mut session = fake(|receiver| {
            let _owned = receiver.recv().unwrap();
            panic!("intentional worker failure");
        });
        assert_eq!(
            session.analyze_page(page(), request()).unwrap_err().code,
            ErrorCode::WorkerFailed
        );
        assert_eq!(session.close().unwrap_err().code, ErrorCode::WorkerFailed);
        session.close().unwrap();
    }
    #[test]
    fn fatal_native_failure_prevents_further_requests() {
        let mut session = fake(|receiver| {
            let Request::Analyze(_page, reply) = receiver.recv().unwrap();
            reply
                .send((
                    Err(Error::new(ErrorCode::Backend, "native failure")),
                    Default::default(),
                    true,
                ))
                .unwrap();
            assert!(receiver.recv().is_err());
        });
        assert_eq!(
            session.analyze_page(page(), request()).unwrap_err().code,
            ErrorCode::Backend
        );
        assert_eq!(
            session.analyze_page(page(), request()).unwrap_err().code,
            ErrorCode::WorkerFailed
        );
        session.close().unwrap();
    }
    #[cfg(feature = "coreml")]
    #[test]
    #[ignore = "requires explicit verified M2 bundle"]
    fn native_session_reuse_and_recovery() {
        let path = std::env::var_os("PODOCO_M2_BUNDLE").expect("bundle path");
        let mut low = options();
        low.limits = ResourceLimits::new(1, 4, 1, 1, 1, 1, 1).unwrap();
        assert_eq!(
            LayoutSession::open(ModelBundle::verify(&path).unwrap(), low)
                .err()
                .unwrap()
                .code,
            ErrorCode::LimitExceeded
        );
        let mut session =
            LayoutSession::open(ModelBundle::verify(&path).unwrap(), options()).unwrap();
        let mut unsupported = request();
        unsupported.formula_scope = FormulaScope::All;
        assert_eq!(
            session.analyze_page(page(), unsupported).unwrap_err().code,
            ErrorCode::UnsupportedCapability
        );
        for expected in 1..=3 {
            session
                .analyze_page(page(), request())
                .unwrap()
                .validate(true)
                .unwrap();
            assert_eq!(session.stats().model_loads, 1);
            assert_eq!(session.stats().predictions, expected);
        }
        session.close().unwrap();
        session.close().unwrap();
        assert_eq!(
            session.analyze_page(page(), request()).unwrap_err().code,
            ErrorCode::InvalidInput
        );
    }
}
