use super::*;
use crate::{
    Affine, AlphaMode, FormulaScope, ImageDescriptor, PageImage, PageKey, PageSpace, ProfileId,
    ResourceLimits,
    domain::Sha256Digest,
    options::ComputePolicy,
    results::{ModelProvenance, PageProvenance, PipelineProvenance, UpdatePayload},
};
use std::sync::mpsc;

fn descriptor(index: u32) -> PageDescriptor {
    PageDescriptor {
        key: PageKey {
            document: DocumentRef::new("test", "revision").unwrap(),
            page_index: index,
        },
        space: PageSpace::new(2., 2.).unwrap(),
    }
}
fn pixels(request: PageRequest) -> Result<PageInput> {
    PageInput::new(
        request.page,
        PageImage::copy(
            ImageDescriptor::new(2, 2, 8, PixelFormat::Rgba8, AlphaMode::Opaque)?,
            &[255; 16],
            request.byte_budget,
        )?,
        Affine::new([1., 0., 0., 1., 0., 0.])?,
        ProfileId::new("test-render")?,
    )
    .map_err(|e| e.error)
}
fn limits() -> ResourceLimits {
    ResourceLimits::new(2, 16, 2, 200_000, 100_000, 96_000_000, 1).unwrap()
}
fn options() -> AnalysisOptions {
    let mut options = AnalysisOptions::new(ProfileId::new("test-profile").unwrap());
    options.formula_scope = FormulaScope::None;
    options
}
struct Fake;
impl engine::Pipeline for Fake {
    fn capabilities(&self) -> Capabilities {
        Capabilities {
            layout: true,
            formula_recognition: false,
            polygons: false,
            reading_order: false,
        }
    }
    fn layout(&mut self, input: &PageInput, _: &AnalysisOptions) -> Result<crate::PageAnalysis> {
        Ok(crate::PageAnalysis {
            page: input.descriptor().clone(),
            provenance: PageProvenance {
                pipeline: PipelineProvenance {
                    sdk_version: ProfileId::new("test").unwrap(),
                    backend: ProfileId::new("test").unwrap(),
                    compute_policy: ComputePolicy::CpuOnly,
                    adapter: ProfileId::new("test").unwrap(),
                    profile: ProfileId::new("test-profile").unwrap(),
                    models: vec![ModelProvenance {
                        model_id: ProfileId::new("test").unwrap(),
                        manifest_sha256: Sha256Digest::of_bytes(b"test"),
                        artifacts: [("test".into(), Sha256Digest::of_bytes(b"test"))].into(),
                    }],
                },
                render_profile: input.render_profile().clone(),
                image: input.image().descriptor(),
                pixel_to_page: input.pixel_to_page(),
            },
            formula_scope: FormulaScope::None,
            regions: vec![],
            formulas: vec![],
            reading_order: None,
            diagnostics: vec![],
        })
    }
}
fn analyzer() -> Analyzer {
    Analyzer::start(
        Box::new(Fake),
        "test-profile".into(),
        AnalyzerOptions {
            compute_policy: ComputePolicy::CpuOnly,
            limits: limits(),
        },
    )
    .unwrap()
}

mod explicit_crops {
    use super::*;
    use crate::{
        FormulaCrop, FormulaRequest, Rect, RegionId,
        formula::{FormulaCancellation, FormulaInput},
    };

    fn crop(id: u32) -> FormulaCrop {
        FormulaCrop {
            page: descriptor(0),
            region_id: RegionId(id),
            bounds: Rect::new(0., 0., 2., 2.).unwrap(),
            display_kind: FormulaDisplayKind::Inline,
        }
    }
    fn render(r: FormulaRequest) -> Result<PageInput> {
        tracked_crop(r, Arc::new(AtomicUsize::new(0)))
    }
    fn tracked_crop(r: FormulaRequest, counter: Arc<AtomicUsize>) -> Result<PageInput> {
        PageInput::new(
            r.crop.page,
            PageImage::owned_for_test(
                ImageDescriptor::new(2, 2, 8, PixelFormat::Rgba8, AlphaMode::Opaque)?,
                vec![255; 16],
                Box::new(move || {
                    counter.fetch_add(1, Ordering::SeqCst);
                }),
            ),
            Affine::new([1., 0., 0., 1., 0., 0.])?,
            ProfileId::new("test-crop")?,
        )
        .map_err(|e| e.error)
    }
    struct Pipeline {
        calls: Arc<Mutex<Vec<String>>>,
        gate: Option<(mpsc::Sender<()>, mpsc::Receiver<()>)>,
    }
    impl engine::Pipeline for Pipeline {
        fn capabilities(&self) -> Capabilities {
            Capabilities {
                formula_recognition: true,
                ..engine::Pipeline::capabilities(&Fake)
            }
        }
        fn layout(
            &mut self,
            input: &PageInput,
            options: &AnalysisOptions,
        ) -> Result<crate::PageAnalysis> {
            self.calls.lock().unwrap().push("layout".into());
            engine::Pipeline::layout(&mut Fake, input, options)
        }
        fn recognize_crop(
            &mut self,
            input: FormulaInput,
            _: FormulaCancellation,
        ) -> Result<FormulaOutcome> {
            self.calls
                .lock()
                .unwrap()
                .push(format!("crop:{}", input.region_id.0));
            if let Some((entered, release)) = self.gate.take() {
                entered.send(()).unwrap();
                release.recv_timeout(DEADLINE).unwrap();
            }
            let provenance = engine::Pipeline::layout(&mut Fake, &input.page, &options())?
                .provenance
                .pipeline;
            Ok(match input.region_id.0 {
                2 => FormulaOutcome::Failed {
                    error: Error::new(ErrorCode::Recognition, "failed"),
                },
                3 => FormulaOutcome::Truncated {
                    partial_latex: Some("x{".into()),
                    error: Error::new(ErrorCode::LimitExceeded, "cap"),
                    provenance,
                },
                5 => panic!("crop native panic"),
                6 => return Err(Error::new(ErrorCode::Backend, "crop native failure")),
                id => FormulaOutcome::Recognized {
                    formula: RecognizedFormula {
                        latex: if id == 8 {
                            "x".repeat(200_000)
                        } else {
                            "x+1".into()
                        },
                        display_kind: if id == 4 {
                            FormulaDisplayKind::Displayed
                        } else {
                            input.display_kind
                        },
                        score: None,
                        provenance,
                    },
                },
            })
        }
    }
    fn create(
        gate: Option<(mpsc::Sender<()>, mpsc::Receiver<()>)>,
    ) -> (Analyzer, Arc<Mutex<Vec<String>>>) {
        let calls = Arc::new(Mutex::new(vec![]));
        (
            Analyzer::start(
                Box::new(Pipeline {
                    calls: calls.clone(),
                    gate,
                }),
                "test-profile".into(),
                AnalyzerOptions {
                    compute_policy: ComputePolicy::CpuOnly,
                    limits: limits(),
                },
            )
            .unwrap(),
            calls,
        )
    }

    #[test]
    fn explicit_crop_has_no_layout_updates_and_preserves_identity() {
        let (analyzer, calls) = create(None);
        let job = analyzer.recognize_formula(crop(1), render).unwrap();
        let result = job.wait().unwrap();
        assert_eq!(result.analysis_id, *job.id());
        assert_eq!(result.crop, crop(1));
        assert_eq!(result.status, CompletionStatus::Completed);
        assert!(matches!(
            result.outcome,
            Some(FormulaOutcome::Recognized { .. })
        ));
        assert_eq!(result.progress.input_bytes, 0);
        assert_eq!(result.progress.peak_input_bytes, 16);
        assert!(result.progress.peak_result_bytes > 0);
        assert_eq!(*calls.lock().unwrap(), ["crop:1"]);
        job.cancellation().cancel();
        assert_eq!(
            job.progress().cancellation_requested,
            result.progress.cancellation_requested
        );
        assert_eq!(job.wait().unwrap().status, CompletionStatus::Completed);
    }

    #[test]
    fn crop_and_document_share_fifo_capacity_without_eager_rendering() {
        let (analyzer, calls) = create(None);
        let (entered, start) = mpsc::channel();
        let (release, gate) = mpsc::channel();
        let first = analyzer
            .analyze_page(
                descriptor(0),
                options(),
                move |r| {
                    entered.send(()).unwrap();
                    gate.recv_timeout(DEADLINE).unwrap();
                    pixels(r)
                },
                |_| Ok(()),
            )
            .unwrap();
        start.recv_timeout(DEADLINE).unwrap();
        let second = analyzer.recognize_formula(crop(1), render).unwrap();
        let third = analyzer
            .analyze_page(descriptor(1), options(), pixels, |_| Ok(()))
            .unwrap();
        let full = analyzer.recognize_formula(crop(1), |_| panic!("rejected loader ran"));
        assert_eq!(full.err().unwrap().code, ErrorCode::LimitExceeded);
        assert_eq!(second.progress().phase, JobPhase::Queued);
        assert_eq!(second.progress().input_bytes, 0);
        release.send(()).unwrap();
        assert_eq!(first.wait().unwrap().status, CompletionStatus::Completed);
        assert_eq!(second.wait().unwrap().status, CompletionStatus::Completed);
        assert_eq!(third.wait().unwrap().status, CompletionStatus::Completed);
        assert_eq!(*calls.lock().unwrap(), ["layout", "crop:1", "layout"]);
    }

    #[test]
    fn queued_crop_cancel_releases_captures_before_completion() {
        struct Capture(Arc<AtomicUsize>);
        impl Drop for Capture {
            fn drop(&mut self) {
                self.0.fetch_add(1, Ordering::SeqCst);
            }
        }
        let (entered, start) = mpsc::channel();
        let (release, gate) = mpsc::channel();
        let (analyzer, calls) = create(Some((entered, gate)));
        let first = analyzer.recognize_formula(crop(1), render).unwrap();
        start.recv_timeout(DEADLINE).unwrap();
        let dropped = Arc::new(AtomicUsize::new(0));
        let capture = Capture(dropped.clone());
        let later = analyzer
            .recognize_formula(crop(2), move |_| {
                drop(capture);
                panic!("cancelled loader ran")
            })
            .unwrap();
        later.cancel();
        assert_eq!(dropped.load(Ordering::SeqCst), 0);
        release.send(()).unwrap();
        first.wait().unwrap();
        assert_eq!(later.wait().unwrap().status, CompletionStatus::Cancelled);
        assert_eq!(dropped.load(Ordering::SeqCst), 1);
        assert_eq!(*calls.lock().unwrap(), ["crop:1"]);
    }

    #[test]
    fn crop_cancel_during_prediction_drains_pixels_then_reuses_session() {
        let (entered, start) = mpsc::channel();
        let (release, gate) = mpsc::channel();
        let (analyzer, _) = create(Some((entered, gate)));
        let released = Arc::new(AtomicUsize::new(0));
        let counter = released.clone();
        let job = analyzer
            .recognize_formula(crop(1), move |r| tracked_crop(r, counter))
            .unwrap();
        start.recv_timeout(DEADLINE).unwrap();
        job.cancel();
        assert!(job.try_outcome().is_none());
        assert_eq!(job.progress().input_bytes, 16);
        assert_eq!(released.load(Ordering::SeqCst), 0);
        release.send(()).unwrap();
        let outcome = job.wait().unwrap();
        assert_eq!(outcome.status, CompletionStatus::Cancelled);
        assert!(outcome.outcome.is_none());
        assert_eq!(released.load(Ordering::SeqCst), 1);
        assert_eq!(
            analyzer
                .recognize_formula(crop(1), render)
                .unwrap()
                .wait()
                .unwrap()
                .status,
            CompletionStatus::Completed
        );
    }

    #[test]
    fn crop_source_errors_context_mismatch_and_result_budget_are_owned() {
        let (analyzer, _) = create(None);
        for id in [2, 3] {
            let outcome = analyzer
                .recognize_formula(crop(id), render)
                .unwrap()
                .wait()
                .unwrap();
            assert_eq!(outcome.status, CompletionStatus::Partial);
            assert!(outcome.error.is_none());
        }
        for (id, expected) in [(4, ErrorCode::InvalidResult), (8, ErrorCode::LimitExceeded)] {
            let outcome = analyzer
                .recognize_formula(crop(id), render)
                .unwrap()
                .wait()
                .unwrap();
            assert_eq!(outcome.status, CompletionStatus::Failed);
            assert_eq!(outcome.error.unwrap().code, expected);
        }
        let wrong = analyzer
            .recognize_formula(crop(1), |mut r| {
                r.crop.page.key.page_index = 9;
                render(r)
            })
            .unwrap()
            .wait()
            .unwrap();
        assert_eq!(wrong.error.unwrap().code, ErrorCode::SourceChanged);
        let panicked = analyzer
            .recognize_formula(crop(1), |_| panic!("loader panic"))
            .unwrap()
            .wait()
            .unwrap();
        assert_eq!(panicked.error.unwrap().code, ErrorCode::PageSource);
        assert_eq!(
            analyzer
                .recognize_formula(crop(1), render)
                .unwrap()
                .wait()
                .unwrap()
                .status,
            CompletionStatus::Completed
        );
        let mut outside = crop(1);
        outside.bounds = Rect::new(-1., 0., 1., 1.).unwrap();
        assert_eq!(
            analyzer
                .recognize_formula(outside, render)
                .err()
                .unwrap()
                .code,
            ErrorCode::InvalidInput
        );
        assert_eq!(
            super::analyzer()
                .recognize_formula(crop(1), render)
                .err()
                .unwrap()
                .code,
            ErrorCode::UnsupportedCapability
        );
    }

    #[test]
    fn crop_native_panic_or_failure_drains_and_fails_queued_documents() {
        for id in [5, 6] {
            let (entered, start) = mpsc::channel();
            let (release, gate) = mpsc::channel();
            let (analyzer, _) = create(Some((entered, gate)));
            let first = analyzer.recognize_formula(crop(id), render).unwrap();
            start.recv_timeout(DEADLINE).unwrap();
            let next = analyzer
                .analyze_page(
                    descriptor(1),
                    options(),
                    |_| panic!("failed lane rendered"),
                    |_| Ok(()),
                )
                .unwrap();
            release.send(()).unwrap();
            assert_eq!(first.wait().unwrap().status, CompletionStatus::Failed);
            assert_eq!(next.wait().unwrap().status, CompletionStatus::Failed);
            assert!(analyzer.recognize_formula(crop(1), render).is_err());
        }
    }

    #[test]
    fn crop_drain_barrier_holds_shared_lane_until_foreign_release_acknowledgement() {
        let (analyzer, calls) = create(None);
        let released = Arc::new(AtomicUsize::new(0));
        let counter = released.clone();
        let (entered, started) = mpsc::channel();
        let (release, gate) = mpsc::channel();
        let job = analyzer
            .recognize_formula_with_drain(
                crop(1),
                move |r| tracked_crop(r, counter),
                move || {
                    entered.send(()).unwrap();
                    gate.recv_timeout(DEADLINE).unwrap();
                    Ok(())
                },
            )
            .unwrap();
        started.recv_timeout(DEADLINE).unwrap();
        assert_eq!(released.load(Ordering::SeqCst), 1);
        assert_eq!(job.progress().phase, JobPhase::Finishing);
        assert_eq!(job.progress().input_bytes, 16);
        assert!(job.try_outcome().is_none());
        let next = analyzer
            .analyze_page(descriptor(0), options(), pixels, |_| Ok(()))
            .unwrap();
        assert_eq!(next.progress().phase, JobPhase::Queued);
        assert_eq!(*calls.lock().unwrap(), ["crop:1"]);
        release.send(()).unwrap();
        assert_eq!(job.wait().unwrap().status, CompletionStatus::Completed);
        assert_eq!(next.wait().unwrap().status, CompletionStatus::Completed);
    }

    #[test]
    fn crop_drain_failure_is_authoritative_and_callback_wait_is_rejected() {
        let (analyzer, _) = create(None);
        let analyzer = Arc::new(analyzer);
        let job = analyzer
            .recognize_formula_with_drain(crop(1), render, || panic!("drain panic"))
            .unwrap();
        assert_eq!(job.wait().unwrap().error.unwrap().code, ErrorCode::Delivery);
        let owner = analyzer.clone();
        let next = analyzer
            .recognize_formula_with_drain(crop(1), render, move || {
                assert_eq!(owner.close().unwrap_err().code, ErrorCode::InvalidInput);
                Ok(())
            })
            .unwrap();
        assert_eq!(next.wait().unwrap().status, CompletionStatus::Cancelled);
        analyzer.close().unwrap();
    }
}

#[test]
fn eager_job_completes_without_progress_subscription() {
    let analyzer = analyzer();
    let (sent, received) = mpsc::channel();
    let job = analyzer
        .analyze_page(descriptor(7), options(), pixels, move |u| {
            sent.send(u).unwrap();
            Ok(())
        })
        .unwrap();
    let outcome = job.wait().unwrap();
    assert_eq!(outcome.status, CompletionStatus::Completed);
    assert_eq!(outcome.summary.counts.pages_finished, 1);
    assert_eq!(outcome.delivered.updates_acknowledged, 3);
    assert!(outcome.delivered.document_finished);
    assert_eq!(outcome.progress.input_bytes, 0);
    assert_eq!(outcome.progress.pending_updates, 0);
    let updates: Vec<_> = received.try_iter().collect();
    assert_eq!(
        updates.iter().map(|u| u.sequence()).collect::<Vec<_>>(),
        [0, 1, 2]
    );
    assert!(matches!(
        updates[0].payload(),
        UpdatePayload::PageLayoutReady { .. }
    ));
    assert!(matches!(
        updates[1].payload(),
        UpdatePayload::PageFinished { .. }
    ));
    assert!(matches!(
        updates[2].payload(),
        UpdatePayload::DocumentFinished { .. }
    ));
    job.close().unwrap();
    job.close().unwrap();
    analyzer.close().unwrap();
    analyzer.close().unwrap();
}

use std::sync::atomic::{AtomicUsize, Ordering};
const DEADLINE: Duration = Duration::from_secs(5);
struct Source<F> {
    pages: Vec<PageDescriptor>,
    load: F,
}
impl<F: FnMut(PageRequest) -> Result<PageInput> + Send + 'static> PageSource for Source<F> {
    fn document(&self) -> &DocumentRef {
        &self.pages[0].key.document
    }
    fn pages(&self) -> &[PageDescriptor] {
        &self.pages
    }
    fn load_page(&mut self, r: PageRequest) -> Result<PageInput> {
        (self.load)(r)
    }
}
fn source<F: FnMut(PageRequest) -> Result<PageInput> + Send + 'static>(
    count: u32,
    load: F,
) -> Source<F> {
    Source {
        pages: (0..count).map(descriptor).collect(),
        load,
    }
}
fn tracked(r: PageRequest, released: Arc<AtomicUsize>) -> Result<PageInput> {
    let image = PageImage::owned_for_test(
        ImageDescriptor::new(2, 2, 8, PixelFormat::Rgba8, AlphaMode::Opaque)?,
        vec![255; 16],
        Box::new(move || {
            released.fetch_add(1, Ordering::SeqCst);
        }),
    );
    PageInput::new(
        r.page,
        image,
        Affine::new([1., 0., 0., 1., 0., 0.])?,
        ProfileId::new("test-render")?,
    )
    .map_err(|e| e.error)
}
fn wait_progress(job: &AnalysisJob, check: impl Fn(&AnalysisProgress) -> bool) {
    let state = job.shared.lock();
    let (state, timeout) = job
        .shared
        .changed
        .wait_timeout_while(state, DEADLINE, |s| !check(&s.progress))
        .unwrap();
    assert!(
        !timeout.timed_out(),
        "progress deadline: {:?}",
        state.progress
    );
    assert!(check(&state.progress));
}
#[test]
fn slow_sink_is_bounded_and_cancel_releases_images_before_sink_returns() {
    let analyzer = analyzer();
    let released = Arc::new(AtomicUsize::new(0));
    let counter = released.clone();
    let (entered, entered_rx) = mpsc::channel();
    let (resume, resume_rx) = mpsc::channel();
    let (sent, updates) = mpsc::channel();
    let mut first = true;
    let job = analyzer
        .analyze_document(
            source(3, move |r| tracked(r, counter.clone())),
            options(),
            move |u| {
                if first {
                    first = false;
                    entered.send(()).unwrap();
                    resume_rx.recv_timeout(DEADLINE).unwrap();
                }
                sent.send(u).unwrap();
                Ok(())
            },
        )
        .unwrap();
    entered_rx.recv_timeout(DEADLINE).unwrap();
    wait_progress(&job, |p| {
        p.processed.pages_finished == 2 && p.pending_updates == 2
    });
    assert_eq!(released.load(Ordering::SeqCst), 2);
    assert_eq!(job.progress().input_bytes, 0);
    job.cancel();
    assert!(job.cancellation().is_cancelled());
    assert_eq!(released.load(Ordering::SeqCst), 2);
    resume.send(()).unwrap();
    let outcome = job.wait().unwrap();
    assert_eq!(outcome.status, CompletionStatus::Cancelled);
    assert_eq!(outcome.summary.counts.pages_finished, 2);
    assert_eq!(outcome.delivered.pages_finished, 0);
    assert_eq!(outcome.progress.peak_input_bytes, 16);
    assert!(outcome.progress.peak_result_bytes <= limits().result_bytes());
    assert!(outcome.progress.peak_pending_updates <= limits().pending_updates());
    assert_eq!(outcome.progress.pending_result_bytes, 0);
    let kinds: Vec<_> = updates.try_iter().map(|u| u.payload().clone()).collect();
    assert_eq!(kinds.len(), 2);
    assert!(matches!(kinds[0], UpdatePayload::PageLayoutReady { .. }));
    assert!(matches!(kinds[1], UpdatePayload::DocumentFinished { .. }));
}
#[test]
fn late_render_after_cancel_is_released_without_prediction_or_layout_delivery() {
    let analyzer = analyzer();
    let released = Arc::new(AtomicUsize::new(0));
    let counter = released.clone();
    let (entered, rx) = mpsc::channel();
    let (cancelled, cancelled_rx) = mpsc::channel();
    let (finish, finish_rx) = mpsc::channel();
    let job = analyzer
        .analyze_page(
            descriptor(0),
            options(),
            move |r| {
                let image = tracked(r.clone(), counter)?;
                entered.send(()).unwrap();
                assert!(r.cancellation.wait_cancelled(DEADLINE));
                cancelled.send(()).unwrap();
                finish_rx.recv_timeout(DEADLINE).unwrap();
                Ok(image)
            },
            |u| {
                assert!(matches!(
                    u.payload(),
                    UpdatePayload::DocumentFinished { .. }
                ));
                Ok(())
            },
        )
        .unwrap();
    rx.recv_timeout(DEADLINE).unwrap();
    assert_eq!(released.load(Ordering::SeqCst), 0);
    job.cancel();
    cancelled_rx.recv_timeout(DEADLINE).unwrap();
    assert_eq!(job.progress().input_bytes, limits().input_bytes());
    assert_eq!(released.load(Ordering::SeqCst), 0);
    finish.send(()).unwrap();
    let outcome = job.wait().unwrap();
    assert_eq!(outcome.status, CompletionStatus::Cancelled);
    assert_eq!(outcome.summary.counts.pages_finished, 0);
    assert_eq!(released.load(Ordering::SeqCst), 1);
}
#[test]
fn terminal_sink_failure_is_authoritative_even_after_completed_processing() {
    let analyzer = analyzer();
    let job = analyzer
        .analyze_page(descriptor(0), options(), pixels, |u| {
            if matches!(u.payload(), UpdatePayload::DocumentFinished { .. }) {
                Err(Error::new(ErrorCode::Io, "persistence failed"))
            } else {
                Ok(())
            }
        })
        .unwrap();
    let outcome = job.wait().unwrap();
    assert_eq!(outcome.status, CompletionStatus::Failed);
    assert_eq!(outcome.summary.status, CompletionStatus::Completed);
    assert_eq!(outcome.error.unwrap().code, ErrorCode::Delivery);
    assert_eq!(outcome.delivered.updates_acknowledged, 2);
    assert_eq!(outcome.delivered.pages_finished, 1);
    assert!(!outcome.delivered.document_finished);
    assert_eq!(outcome.progress.pending_result_bytes, 0);
}
#[test]
fn sink_panic_and_source_panic_are_contained() {
    let analyzer = analyzer();
    let sink = analyzer
        .analyze_page(descriptor(0), options(), pixels, |_| {
            panic!("intentional sink panic")
        })
        .unwrap();
    let result = sink.wait().unwrap();
    assert_eq!(result.error.unwrap().code, ErrorCode::Delivery);
    let source = analyzer
        .analyze_page(
            descriptor(0),
            options(),
            |_| panic!("intentional source panic"),
            |_| Ok(()),
        )
        .unwrap();
    let result = source.wait().unwrap();
    assert_eq!(result.error.unwrap().code, ErrorCode::WorkerFailed);
    let healthy = analyzer
        .analyze_page(descriptor(0), options(), pixels, |_| Ok(()))
        .unwrap();
    assert_eq!(healthy.wait().unwrap().status, CompletionStatus::Completed);
}
#[test]
fn page_failures_continue_and_do_not_retain_failed_images() {
    let analyzer = analyzer();
    let (sent, received) = mpsc::channel();
    let job = analyzer
        .analyze_document(
            source(3, |r| {
                if r.page.key.page_index == 1 {
                    return Err(Error::new(ErrorCode::PageSource, "renderer failed"));
                }
                pixels(r)
            }),
            options(),
            move |u| {
                sent.send(u).unwrap();
                Ok(())
            },
        )
        .unwrap();
    let outcome = job.wait().unwrap();
    assert_eq!(outcome.status, CompletionStatus::Partial);
    assert_eq!(outcome.summary.counts.pages_finished, 2);
    assert_eq!(outcome.summary.counts.pages_failed, 1);
    let updates: Vec<_> = received.try_iter().collect();
    assert_eq!(updates.len(), 6);
    assert!(
        matches!(updates[2].payload(),UpdatePayload::PageFailed {page_key,..} if page_key.page_index==1)
    );
    assert_eq!(
        updates.iter().map(|u| u.sequence()).collect::<Vec<_>>(),
        [0, 1, 2, 3, 4, 5]
    );
}
#[test]
fn wrong_revision_and_oversized_source_inputs_are_rejected() {
    let analyzer = analyzer();
    let wrong = analyzer
        .analyze_page(
            descriptor(0),
            options(),
            |mut r| {
                r.page.key.document = DocumentRef::new("test", "changed").unwrap();
                pixels(r)
            },
            |_| Ok(()),
        )
        .unwrap();
    assert_eq!(
        wrong.wait().unwrap().error.unwrap().code,
        ErrorCode::SourceChanged
    );
    let large = analyzer
        .analyze_page(
            descriptor(0),
            options(),
            |r| {
                PageInput::new(
                    r.page,
                    PageImage::copy(
                        ImageDescriptor::new(2, 2, 8, PixelFormat::Rgba8, AlphaMode::Opaque)?,
                        &[255; 20],
                        20,
                    )?,
                    Affine::new([1., 0., 0., 1., 0., 0.])?,
                    ProfileId::new("test")?,
                )
                .map_err(|e| e.error)
            },
            |_| Ok(()),
        )
        .unwrap();
    let result = large.wait().unwrap();
    assert_eq!(result.status, CompletionStatus::Partial);
    assert_eq!(result.summary.counts.pages_failed, 1);
}
#[test]
fn bounded_fifo_queued_cancellation_never_renders() {
    let analyzer = analyzer();
    let (started, rx) = mpsc::channel();
    let (release, release_rx) = mpsc::channel();
    let active = analyzer
        .analyze_page(
            descriptor(0),
            options(),
            move |r| {
                started.send(()).unwrap();
                release_rx.recv_timeout(DEADLINE).unwrap();
                pixels(r)
            },
            |_| Ok(()),
        )
        .unwrap();
    rx.recv_timeout(DEADLINE).unwrap();
    let calls = Arc::new(AtomicUsize::new(0));
    let counter = calls.clone();
    let cancelled = analyzer
        .analyze_page(
            descriptor(1),
            options(),
            move |r| {
                counter.fetch_add(1, Ordering::SeqCst);
                pixels(r)
            },
            |_| Ok(()),
        )
        .unwrap();
    let later = analyzer
        .analyze_page(descriptor(2), options(), pixels, |_| Ok(()))
        .unwrap();
    assert_ne!(active.id(), later.id());
    let full = analyzer.analyze_page(
        descriptor(3),
        options(),
        |_| panic!("full queue rendered"),
        |_| Ok(()),
    );
    assert_eq!(full.err().unwrap().code, ErrorCode::LimitExceeded);
    cancelled.cancel();
    release.send(()).unwrap();
    assert_eq!(active.wait().unwrap().status, CompletionStatus::Completed);
    assert_eq!(
        cancelled.wait().unwrap().status,
        CompletionStatus::Cancelled
    );
    assert_eq!(later.wait().unwrap().status, CompletionStatus::Completed);
    assert_eq!(calls.load(Ordering::SeqCst), 0);
}
#[test]
fn metadata_and_capabilities_fail_before_rendering() {
    let analyzer = analyzer();
    let mut all = options();
    all.formula_scope = FormulaScope::All;
    assert_eq!(
        analyzer
            .analyze_page(
                descriptor(0),
                all,
                |_| panic!("unsupported render"),
                |_| Ok(())
            )
            .err()
            .unwrap()
            .code,
        ErrorCode::UnsupportedCapability
    );
    let duplicate = Source {
        pages: vec![descriptor(0), descriptor(0)],
        load: pixels,
    };
    assert_eq!(
        analyzer
            .analyze_document(duplicate, options(), |_| Ok(()))
            .err()
            .unwrap()
            .code,
        ErrorCode::InvalidInput
    );
    analyzer.close().unwrap();
    assert_eq!(
        analyzer
            .analyze_page(descriptor(0), options(), pixels, |_| Ok(()))
            .err()
            .unwrap()
            .code,
        ErrorCode::InvalidInput
    );
}
#[test]
fn individual_update_limit_fails_without_unbounded_delivery() {
    let small = ResourceLimits::new(1, 16, 1, 128, 128, 96_000_000, 1).unwrap();
    let analyzer = Analyzer::start(
        Box::new(Fake),
        "test-profile".into(),
        AnalyzerOptions {
            compute_policy: ComputePolicy::CpuOnly,
            limits: small,
        },
    )
    .unwrap();
    let job = analyzer
        .analyze_page(descriptor(0), options(), pixels, |_| {
            panic!("oversized update delivered")
        })
        .unwrap();
    let outcome = job.wait().unwrap();
    assert_eq!(outcome.status, CompletionStatus::Failed);
    assert_eq!(outcome.error.unwrap().code, ErrorCode::LimitExceeded);
    assert!(outcome.progress.peak_result_bytes <= 128);
    assert_eq!(outcome.progress.pending_updates, 0);
}

struct Controlled<F>(F);
impl<F: FnMut(&PageInput, &AnalysisOptions) -> Result<crate::PageAnalysis> + Send> engine::Pipeline
    for Controlled<F>
{
    fn capabilities(&self) -> Capabilities {
        engine::Pipeline::capabilities(&Fake)
    }
    fn layout(
        &mut self,
        input: &PageInput,
        options: &AnalysisOptions,
    ) -> Result<crate::PageAnalysis> {
        (self.0)(input, options)
    }
}
#[test]
fn cancellation_during_prediction_preserves_lease_until_prediction_returns() {
    let (entered, rx) = mpsc::channel();
    let (resume, resume_rx) = mpsc::channel();
    let pipeline = Controlled(move |input: &PageInput, options: &AnalysisOptions| {
        entered.send(()).unwrap();
        resume_rx.recv_timeout(DEADLINE).unwrap();
        engine::Pipeline::layout(&mut Fake, input, options)
    });
    let analyzer = Analyzer::start(
        Box::new(pipeline),
        "test-profile".into(),
        AnalyzerOptions {
            compute_policy: ComputePolicy::CpuOnly,
            limits: limits(),
        },
    )
    .unwrap();
    let released = Arc::new(AtomicUsize::new(0));
    let counter = released.clone();
    let job = analyzer
        .analyze_page(
            descriptor(0),
            options(),
            move |r| tracked(r, counter),
            |_| Ok(()),
        )
        .unwrap();
    rx.recv_timeout(DEADLINE).unwrap();
    job.cancel();
    assert_eq!(released.load(Ordering::SeqCst), 0);
    resume.send(()).unwrap();
    assert_eq!(job.wait().unwrap().status, CompletionStatus::Cancelled);
    assert_eq!(released.load(Ordering::SeqCst), 1);
}
#[test]
fn pipeline_panic_finishes_active_and_queued_jobs_and_closes_analyzer() {
    let (entered, rx) = mpsc::channel();
    let (resume, resume_rx) = mpsc::channel();
    let pipeline = Controlled(move |_: &PageInput, _: &AnalysisOptions| {
        entered.send(()).unwrap();
        resume_rx.recv_timeout(DEADLINE).unwrap();
        panic!("intentional pipeline panic")
    });
    let analyzer = Analyzer::start(
        Box::new(pipeline),
        "test-profile".into(),
        AnalyzerOptions {
            compute_policy: ComputePolicy::CpuOnly,
            limits: limits(),
        },
    )
    .unwrap();
    let active = analyzer
        .analyze_page(descriptor(0), options(), pixels, |_| Ok(()))
        .unwrap();
    rx.recv_timeout(DEADLINE).unwrap();
    let queued = analyzer
        .analyze_page(
            descriptor(1),
            options(),
            |_| panic!("queued after pipeline failure"),
            |_| Ok(()),
        )
        .unwrap();
    resume.send(()).unwrap();
    assert_eq!(
        active.wait().unwrap().error.unwrap().code,
        ErrorCode::WorkerFailed
    );
    assert_eq!(
        queued.wait().unwrap().error.unwrap().code,
        ErrorCode::WorkerFailed
    );
    assert_eq!(
        analyzer
            .analyze_page(descriptor(2), options(), pixels, |_| Ok(()))
            .err()
            .unwrap()
            .code,
        ErrorCode::WorkerFailed
    );
    analyzer.close().unwrap();
}

#[test]
fn sink_failure_cancels_an_active_source_callback_without_waiting_for_it() {
    let analyzer = analyzer();
    let (rendering, rendering_rx) = mpsc::channel();
    let observed = Arc::new(AtomicUsize::new(0));
    let counter = observed.clone();
    let job = analyzer
        .analyze_document(
            source(2, move |r| {
                if r.page.key.page_index == 1 {
                    rendering.send(()).unwrap();
                    if r.cancellation.wait_cancelled(DEADLINE) {
                        counter.fetch_add(1, Ordering::SeqCst);
                    }
                }
                pixels(r)
            }),
            options(),
            move |u| {
                if u.sequence() == 0 {
                    rendering_rx.recv_timeout(DEADLINE).unwrap();
                    return Err(Error::new(ErrorCode::Io, "sink failed during rendering"));
                }
                panic!("failed sink called recursively")
            },
        )
        .unwrap();
    assert_eq!(job.wait().unwrap().error.unwrap().code, ErrorCode::Delivery);
    assert_eq!(observed.load(Ordering::SeqCst), 1);
}

use crate::results::{
    FormulaDisplayKind, FormulaOutcome, FormulaResult, FormulaState, LayoutRegion,
    RecognizedFormula, RegionCategory,
};
struct Formulas {
    cancel_second: bool,
    provenance: Option<PipelineProvenance>,
}
impl engine::Pipeline for Formulas {
    fn capabilities(&self) -> Capabilities {
        Capabilities {
            formula_recognition: true,
            ..engine::Pipeline::capabilities(&Fake)
        }
    }
    fn layout(
        &mut self,
        input: &PageInput,
        options: &AnalysisOptions,
    ) -> Result<crate::PageAnalysis> {
        let mut page = engine::Pipeline::layout(&mut Fake, input, options)?;
        self.provenance = Some(page.provenance.pipeline.clone());
        for (id, kind) in [
            (3, FormulaDisplayKind::Inline),
            (7, FormulaDisplayKind::Displayed),
            (9, FormulaDisplayKind::Unknown),
        ] {
            page.regions.push(LayoutRegion {
                id: crate::RegionId(id),
                category: RegionCategory::Formula,
                model_class_id: id,
                model_label: "formula".into(),
                native_subtype: None,
                display_kind: Some(kind),
                bounds: crate::Rect::new(0., 0., 1., 1.)?,
                polygon: None,
                score: None,
                diagnostics: vec![],
            });
            page.formulas.push(FormulaResult {
                region_id: crate::RegionId(id),
                state: FormulaState::NotRequested,
            });
        }
        Ok(page)
    }
    fn recognize(
        &mut self,
        _: &PageInput,
        region: &LayoutRegion,
        cancel: &CancellationHandle,
    ) -> Result<FormulaOutcome> {
        if self.cancel_second && region.id.0 == 7 {
            assert!(cancel.wait_cancelled(DEADLINE));
            return Err(Error::new(ErrorCode::Cancelled, "cancelled recognizer"));
        }
        Ok(match region.id.0 {
            3 => FormulaOutcome::Recognized {
                formula: RecognizedFormula {
                    latex: "\\alpha + β".into(),
                    display_kind: region.display_kind.unwrap(),
                    score: None,
                    provenance: self.provenance.clone().unwrap(),
                },
            },
            7 => FormulaOutcome::Failed {
                error: Error::new(ErrorCode::Recognition, "fixture recognition failed"),
            },
            _ => FormulaOutcome::Truncated {
                partial_latex: Some("\\frac{".into()),
                error: Error::new(ErrorCode::LimitExceeded, "fixture token limit"),
                provenance: self.provenance.clone().unwrap(),
            },
        })
    }
}
fn formula_analyzer(cancel_second: bool) -> Analyzer {
    Analyzer::start(
        Box::new(Formulas {
            cancel_second,
            provenance: None,
        }),
        "test-profile".into(),
        AnalyzerOptions {
            compute_policy: ComputePolicy::CpuOnly,
            limits: limits(),
        },
    )
    .unwrap()
}
#[test]
fn formula_updates_agree_with_final_snapshot_and_counts() {
    let analyzer = formula_analyzer(false);
    let mut options = options();
    options.formula_scope = FormulaScope::All;
    let (sent, received) = mpsc::channel();
    let job = analyzer
        .analyze_page(descriptor(0), options, pixels, move |u| {
            sent.send(u).unwrap();
            Ok(())
        })
        .unwrap();
    let outcome = job.wait().unwrap();
    assert_eq!(outcome.status, CompletionStatus::Partial);
    let c = outcome.summary.counts;
    assert_eq!(
        (
            c.pages_finished,
            c.formulas_detected,
            c.formulas_recognized,
            c.formulas_failed,
            c.formulas_truncated,
            c.formulas_pending
        ),
        (1, 3, 1, 1, 1, 0)
    );
    assert_eq!(outcome.delivered.formulas_finished, 3);
    let updates: Vec<_> = received.try_iter().collect();
    assert_eq!(updates.len(), 6);
    let UpdatePayload::PageLayoutReady { page: initial } = updates[0].payload() else {
        panic!("missing layout")
    };
    assert!(
        initial
            .formulas
            .iter()
            .all(|f| matches!(f.state, FormulaState::Pending))
    );
    let UpdatePayload::PageFinished { page: final_page } = updates[4].payload() else {
        panic!("missing final snapshot")
    };
    for (index, state) in final_page.formulas.iter().enumerate() {
        let UpdatePayload::FormulaFinished {
            region_id, outcome, ..
        } = updates[index + 1].payload()
        else {
            panic!("missing formula update")
        };
        assert_eq!(state.region_id, *region_id);
        assert_eq!(
            state.state,
            FormulaState::Finished {
                outcome: outcome.clone()
            }
        );
    }
    final_page.validate(true).unwrap();
}
#[test]
fn cancellation_between_formulas_preserves_delivered_prefix_and_pending_counts() {
    let analyzer = formula_analyzer(true);
    let mut options = options();
    options.formula_scope = FormulaScope::All;
    let (recognized, rx) = mpsc::channel();
    let (sent, received) = mpsc::channel();
    let job = analyzer
        .analyze_page(descriptor(0), options, pixels, move |u| {
            if matches!(u.payload(), UpdatePayload::FormulaFinished { .. }) {
                recognized.send(()).unwrap();
            }
            sent.send(u).unwrap();
            Ok(())
        })
        .unwrap();
    rx.recv_timeout(DEADLINE).unwrap();
    job.cancel();
    let outcome = job.wait().unwrap();
    assert_eq!(outcome.status, CompletionStatus::Cancelled);
    assert_eq!(outcome.summary.counts.formulas_recognized, 1);
    assert_eq!(outcome.summary.counts.formulas_pending, 2);
    assert_eq!(outcome.summary.counts.pages_finished, 0);
    assert_eq!(outcome.delivered.formulas_finished, 1);
    assert!(
        !received
            .try_iter()
            .any(|u| matches!(u.payload(), UpdatePayload::PageFinished { .. }))
    );
}
#[test]
fn callback_wait_is_rejected_and_does_not_deadlock_delivery() {
    let analyzer = analyzer();
    let slot: Arc<Mutex<Option<Arc<AnalysisJob>>>> = Arc::new(Mutex::new(None));
    let callback_slot = slot.clone();
    let (resume, resume_rx) = mpsc::channel();
    let job = Arc::new(
        analyzer
            .analyze_page(
                descriptor(0),
                options(),
                move |r| {
                    resume_rx.recv_timeout(DEADLINE).unwrap();
                    pixels(r)
                },
                move |_| {
                    let job = callback_slot.lock().unwrap().as_ref().unwrap().clone();
                    assert_eq!(job.wait().unwrap_err().code, ErrorCode::InvalidInput);
                    Ok(())
                },
            )
            .unwrap(),
    );
    *slot.lock().unwrap() = Some(job.clone());
    resume.send(()).unwrap();
    assert_eq!(job.wait().unwrap().status, CompletionStatus::Completed);
    slot.lock().unwrap().take();
}
#[test]
fn analyzer_close_cancels_and_waits_for_callbacks_then_rejects_work() {
    let analyzer = Arc::new(analyzer());
    let (entered, rx) = mpsc::channel();
    let job = analyzer
        .analyze_page(
            descriptor(0),
            options(),
            move |r| {
                entered.send(()).unwrap();
                assert!(r.cancellation.wait_cancelled(DEADLINE));
                pixels(r)
            },
            |_| Ok(()),
        )
        .unwrap();
    rx.recv_timeout(DEADLINE).unwrap();
    let second = analyzer.clone();
    let closer = std::thread::spawn(move || second.close());
    analyzer.close().unwrap();
    closer.join().unwrap().unwrap();
    assert_eq!(job.wait().unwrap().status, CompletionStatus::Cancelled);
    assert_eq!(
        analyzer
            .analyze_page(descriptor(0), options(), pixels, |_| Ok(()))
            .err()
            .unwrap()
            .code,
        ErrorCode::InvalidInput
    );
}

#[test]
fn byte_budget_applies_even_when_item_capacity_remains() {
    let bounded = ResourceLimits::new(1, 16, 50, 100_000, 100_000, 96_000_000, 1).unwrap();
    let analyzer = Analyzer::start(
        Box::new(Fake),
        "test-profile".into(),
        AnalyzerOptions {
            compute_policy: ComputePolicy::CpuOnly,
            limits: bounded,
        },
    )
    .unwrap();
    let (entered, entered_rx) = mpsc::channel();
    let (resume, resume_rx) = mpsc::channel();
    let mut first = true;
    let job = analyzer
        .analyze_document(source(2, pixels), options(), move |_| {
            if first {
                first = false;
                entered.send(()).unwrap();
                resume_rx.recv_timeout(DEADLINE).unwrap();
            }
            Ok(())
        })
        .unwrap();
    entered_rx.recv_timeout(DEADLINE).unwrap();
    let p = job.progress();
    assert_eq!(p.pending_updates, 1);
    assert_eq!(p.peak_pending_updates, 1);
    assert_eq!(p.peak_result_bytes, bounded.max_update_bytes());
    assert_eq!(p.processed.pages_finished, 1);
    job.cancel();
    resume.send(()).unwrap();
    let outcome = job.wait().unwrap();
    assert_eq!(outcome.status, CompletionStatus::Cancelled);
    assert_eq!(outcome.progress.pending_result_bytes, 0);
    assert!(outcome.delivered.document_finished);
}

#[test]
fn revision_change_during_render_releases_the_image_and_fails_job() {
    struct Changing {
        document: DocumentRef,
        pages: Vec<PageDescriptor>,
        released: Arc<AtomicUsize>,
    }
    impl PageSource for Changing {
        fn document(&self) -> &DocumentRef {
            &self.document
        }
        fn pages(&self) -> &[PageDescriptor] {
            &self.pages
        }
        fn load_page(&mut self, r: PageRequest) -> Result<PageInput> {
            let result = tracked(r, self.released.clone());
            self.document = DocumentRef::new("test", "changed").unwrap();
            result
        }
    }
    let analyzer = analyzer();
    let released = Arc::new(AtomicUsize::new(0));
    let job = analyzer
        .analyze_document(
            Changing {
                document: descriptor(0).key.document,
                pages: vec![descriptor(0)],
                released: released.clone(),
            },
            options(),
            |_| Ok(()),
        )
        .unwrap();
    let outcome = job.wait().unwrap();
    assert_eq!(outcome.status, CompletionStatus::Failed);
    assert_eq!(outcome.error.unwrap().code, ErrorCode::SourceChanged);
    assert_eq!(released.load(Ordering::SeqCst), 1);
    assert_eq!(outcome.summary.counts.pages_finished, 0);
    assert!(outcome.delivered.document_finished);
}

#[cfg(feature = "coreml")]
#[test]
#[ignore = "requires explicit verified M2 bundle; executes nine real predictions"]
fn native_document_jobs_match_blocking_pages_and_reuse_model() {
    use crate::{LayoutSession, LayoutSessionStats, PageAnalysis};
    fn native_page(index: u32) -> PageInput {
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/fixtures/pp_doclayout_v3");
        let names = ["columns.png", "equations.png", "raster.png"];
        let file = std::fs::File::open(root.join(names[index as usize])).unwrap();
        let mut decoder = png::Decoder::new(std::io::BufReader::new(file));
        decoder.set_transformations(png::Transformations::EXPAND | png::Transformations::ALPHA);
        let mut reader = decoder.read_info().unwrap();
        let mut pixels = vec![0; reader.output_buffer_size().unwrap()];
        let info = reader.next_frame(&mut pixels).unwrap();
        assert_eq!(info.color_type, png::ColorType::Rgba);
        pixels.truncate(info.buffer_size());
        let (w, h) = (f64::from(info.width), f64::from(info.height));
        let (space, map) = if index == 2 {
            (
                PageSpace::new(h, w).unwrap(),
                Affine::new([0., 1., -1., 0., h, 0.]).unwrap(),
            )
        } else {
            (
                PageSpace::new(w, h).unwrap(),
                Affine::new([1., 0., 0., 1., 0., 0.]).unwrap(),
            )
        };
        PageInput::new(
            PageDescriptor {
                key: descriptor(index).key,
                space,
            },
            PageImage::copy(
                ImageDescriptor::new(
                    info.width,
                    info.height,
                    u64::from(info.width) * 4,
                    PixelFormat::Rgba8,
                    AlphaMode::Straight,
                )
                .unwrap(),
                &pixels,
                4_000_000,
            )
            .unwrap(),
            map,
            ProfileId::new("fixture-raster-v1").unwrap(),
        )
        .unwrap()
    }
    struct Observed {
        session: LayoutSession,
        stats: Arc<Mutex<LayoutSessionStats>>,
    }
    impl engine::Pipeline for Observed {
        fn capabilities(&self) -> Capabilities {
            self.session.capabilities()
        }
        fn layout(&mut self, input: &PageInput, options: &AnalysisOptions) -> Result<PageAnalysis> {
            let result = self.session.analyze_page(input.clone(), options.clone());
            *self.stats.lock().unwrap() = self.session.stats();
            result
        }
        fn failed(&self) -> bool {
            self.session.failed()
        }
    }
    let bundle =
        ModelBundle::verify(std::env::var_os("PODOCO_M2_BUNDLE").expect("bundle path")).unwrap();
    let mut analysis = AnalysisOptions::new(ProfileId::new(&bundle.manifest().profile.id).unwrap());
    analysis.formula_scope = FormulaScope::None;
    let opts = AnalyzerOptions {
        compute_policy: ComputePolicy::CpuAndNeuralEngine,
        limits: ResourceLimits::new(2, 4_000_000, 2, 500_000, 250_000, 96_000_000, 1).unwrap(),
    };
    let mut session = LayoutSession::open(bundle, opts.clone()).unwrap();
    let expected: Vec<_> = (0..3)
        .map(|i| {
            session
                .analyze_page(native_page(i), analysis.clone())
                .unwrap()
        })
        .collect();
    let stats = Arc::new(Mutex::new(session.stats()));
    let analyzer = Analyzer::start(
        Box::new(Observed {
            session,
            stats: stats.clone(),
        }),
        analysis.profile.as_str().into(),
        opts.clone(),
    )
    .unwrap();
    for repetition in 0..2 {
        let pages: Vec<_> = expected.iter().map(|p| p.page.clone()).collect();
        let (sent, updates) = mpsc::channel();
        let job = analyzer
            .analyze_document(
                Source {
                    pages,
                    load: |r: PageRequest| {
                        assert_eq!(r.byte_budget, 4_000_000);
                        Ok(native_page(r.page.key.page_index))
                    },
                },
                analysis.clone(),
                move |u| {
                    sent.send(u).unwrap();
                    Ok(())
                },
            )
            .unwrap();
        let outcome = job.wait().unwrap();
        assert_eq!(outcome.status, CompletionStatus::Completed);
        assert_eq!(outcome.delivered.updates_acknowledged, 7);
        assert_eq!(outcome.delivered.pages_finished, 3);
        assert!(outcome.delivered.document_finished);
        assert_eq!(outcome.progress.input_bytes, 0);
        assert_eq!(outcome.progress.pending_result_bytes, 0);
        assert!(outcome.progress.peak_input_bytes <= opts.limits.input_bytes());
        assert!(outcome.progress.peak_result_bytes <= opts.limits.result_bytes());
        assert!(outcome.progress.peak_pending_updates <= opts.limits.pending_updates());
        let received: Vec<_> = updates.try_iter().collect();
        for (index, reference) in expected.iter().enumerate() {
            match (
                received[index * 2].payload(),
                received[index * 2 + 1].payload(),
            ) {
                (
                    UpdatePayload::PageLayoutReady { page: layout },
                    UpdatePayload::PageFinished { page },
                ) => {
                    assert_eq!(layout.as_ref(), reference);
                    assert_eq!(page.as_ref(), reference);
                }
                _ => panic!("unexpected update ordering"),
            }
        }
        let observed = *stats.lock().unwrap();
        assert_eq!(observed.model_loads, 1);
        assert_eq!(observed.predictions, 6 + repetition * 3);
        assert!(observed.peak_tensor_bytes <= opts.limits.tensor_bytes());
    }
    analyzer.close().unwrap();
}

#[test]
fn cancellation_does_not_hide_a_fatal_native_failure_from_queued_jobs() {
    let (entered, entered_rx) = mpsc::channel();
    let (resume, resume_rx) = mpsc::channel();
    let analyzer = Analyzer::start(
        Box::new(Controlled(move |_: &PageInput, _: &AnalysisOptions| {
            entered.send(()).unwrap();
            resume_rx.recv_timeout(DEADLINE).unwrap();
            Err(Error::new(ErrorCode::Backend, "native prediction failed"))
        })),
        "test-profile".into(),
        AnalyzerOptions {
            compute_policy: ComputePolicy::CpuOnly,
            limits: limits(),
        },
    )
    .unwrap();
    let first = analyzer
        .analyze_page(descriptor(0), options(), pixels, |_| Ok(()))
        .unwrap();
    entered_rx.recv_timeout(DEADLINE).unwrap();
    let queued = analyzer
        .analyze_page(
            descriptor(1),
            options(),
            |_| panic!("queued renderer invoked"),
            |_| Ok(()),
        )
        .unwrap();
    first.cancel();
    resume.send(()).unwrap();
    for job in [&first, &queued] {
        let outcome = job.wait().unwrap();
        assert_eq!(outcome.status, CompletionStatus::Failed);
        assert_eq!(outcome.error.unwrap().code, ErrorCode::Backend);
    }
    analyzer.close().unwrap();
}
