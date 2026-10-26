use crate::*;
use std::sync::atomic::{AtomicUsize, Ordering};
fn descriptor() -> PodocoImageDescriptor {
    PodocoImageDescriptor {
        struct_size: size_of::<PodocoImageDescriptor>() as u32,
        width: 2,
        height: 2,
        pixel_format: 1,
        alpha_mode: 0,
        reserved: 0,
        row_bytes: 8,
    }
}
fn bytes(data: &[u8]) -> PodocoBytes {
    PodocoBytes {
        data: data.as_ptr(),
        len: data.len() as u64,
    }
}
fn take_json(handle: u64) -> serde_json::Value {
    let mut view = PodocoBytes::default();
    // SAFETY: Valid output storage and live buffer; no concurrent release.
    unsafe {
        assert_eq!(
            podoco_buffer_view(handle, &mut view, std::ptr::null_mut()),
            PODOCO_OK
        );
        let value =
            serde_json::from_slice(std::slice::from_raw_parts(view.data, view.len as usize))
                .unwrap();
        assert_eq!(podoco_release(handle), PODOCO_OK);
        value
    }
}
unsafe extern "C" fn released(token: u64) {
    let _ = podoco_live_handles(); // Reentrant registry access proves lock-free release.
    // SAFETY: Tests keep this stable AtomicUsize alive through the last release.
    unsafe {
        (&*(token as *const AtomicUsize)).fetch_add(1, Ordering::SeqCst);
    }
}
#[test]
fn copied_image_is_independent_and_stale_handles_are_rejected() {
    let mut source = [7u8; 16];
    let (mut image, mut error, mut info) = (0, 0, 0);
    // SAFETY: All descriptors/buffers/output scalars are live and disjoint.
    unsafe {
        assert_eq!(
            podoco_image_copy(&descriptor(), bytes(&source), 16, &mut image, &mut error),
            PODOCO_OK
        );
        source.fill(99);
        let entry = handles::get(image, handles::Kind::Image).unwrap();
        let handles::Entry::Image(value) = entry.as_ref() else {
            unreachable!()
        };
        assert_eq!(value.row(0).unwrap(), &[7; 8]);
        assert_eq!(podoco_image_info(image, &mut info, &mut error), PODOCO_OK);
        assert_eq!(take_json(info)["retained_bytes"], 16);
        let mut view = PodocoBytes::default();
        assert_eq!(
            podoco_buffer_view(image, &mut view, &mut error),
            PODOCO_ERROR
        );
        assert_eq!(take_json(error)["code"], "invalid_input");
        assert_eq!(podoco_release(image), PODOCO_OK);
        assert_eq!(podoco_release(image), PODOCO_ERROR);
        assert_eq!(
            podoco_image_info(image, &mut info, &mut error),
            PODOCO_ERROR
        );
        assert_eq!(info, 0);
        take_json(error);
    }
}
#[test]
fn rejected_lease_keeps_caller_ownership_and_accepted_lease_releases_once() {
    let source = vec![9u8; 16];
    let counter = Box::new(AtomicUsize::new(0));
    let token = counter.as_ref() as *const AtomicUsize as u64;
    let (mut image, mut error) = (0, 0);
    // SAFETY: Source remains immutable and alive through final-reader release;
    // the callback's atomic counter outlives all reader threads and notifications.
    unsafe {
        assert_eq!(
            podoco_image_import(
                &descriptor(),
                bytes(&source),
                16,
                15,
                Some(released),
                token,
                &mut image,
                &mut error
            ),
            PODOCO_ERROR
        );
        assert_eq!(image, 0);
        assert_eq!(take_json(error)["code"], "limit_exceeded");
        assert_eq!(counter.load(Ordering::SeqCst), 0);
        assert_eq!(
            podoco_image_import(
                &descriptor(),
                bytes(&source),
                16,
                16,
                Some(released),
                token,
                &mut image,
                &mut error
            ),
            PODOCO_OK
        );
    }
    let entry = handles::get(image, handles::Kind::Image).unwrap();
    let handles::Entry::Image(value) = entry.as_ref() else {
        unreachable!()
    };
    assert_eq!(value.row(0).unwrap().as_ptr(), source.as_ptr());
    let reader = value.clone();
    drop(entry);
    assert_eq!(podoco_release(image), PODOCO_OK);
    assert_eq!(counter.load(Ordering::SeqCst), 0);
    std::thread::spawn(move || {
        assert_eq!(reader.row(1).unwrap(), &[9; 8]);
        drop(reader);
    })
    .join()
    .unwrap();
    assert_eq!(counter.load(Ordering::SeqCst), 1);
    assert_eq!(podoco_release(image), PODOCO_ERROR);
}
#[test]
fn invalid_layout_pointers_lengths_and_schema_fail_before_use() {
    let (mut image, mut error) = (123, 0);
    let mut d = descriptor();
    d.struct_size = 4;
    // SAFETY: Valid size field and disjoint writable scalars. Oversized/null
    // inputs are deliberately rejected before any byte-pointer dereference.
    unsafe {
        assert_eq!(
            podoco_image_copy(&d, PodocoBytes::default(), 16, &mut image, &mut error),
            PODOCO_ERROR
        );
        assert_eq!(image, 0);
        take_json(error);
        assert_eq!(
            podoco_image_copy(
                std::ptr::null(),
                PodocoBytes::default(),
                16,
                &mut image,
                &mut error
            ),
            PODOCO_ERROR
        );
        take_json(error);
        assert_eq!(
            podoco_image_copy(
                &descriptor(),
                PodocoBytes {
                    data: std::ptr::null(),
                    len: 16
                },
                16,
                &mut image,
                &mut error
            ),
            PODOCO_ERROR
        );
        take_json(error);
        assert_eq!(
            podoco_analyzer_open(
                PodocoBytes {
                    data: std::ptr::dangling(),
                    len: PODOCO_MAX_METADATA_BYTES + 1
                },
                &mut image,
                &mut error
            ),
            PODOCO_ERROR
        );
        take_json(error);
        assert_eq!(
            podoco_analyzer_open(bytes(&[0xff]), &mut image, &mut error),
            PODOCO_ERROR
        );
        take_json(error);
        assert_eq!(
            podoco_image_copy(
                &descriptor(),
                bytes(&[0; 16]),
                16,
                std::ptr::null_mut(),
                &mut error
            ),
            PODOCO_ERROR
        );
        take_json(error);
        assert_eq!(
            wire::guard(&mut error, || -> podoco::Result<i32> {
                panic!("contained test panic")
            }),
            PODOCO_ERROR
        );
        assert_eq!(take_json(error)["code"], "worker_failed");
    }
    assert_eq!(podoco_release(0), PODOCO_OK);
    assert_eq!(
        wire::schema(999).unwrap_err().code,
        podoco::ErrorCode::UnsupportedSchema
    );
}

#[test]
fn formula_extension_rejects_invalid_metadata_before_assets_or_models() {
    assert_ne!(podoco_features() & PODOCO_FEATURE_FORMULA, 0);
    let (mut output, mut error) = (123, 0);
    let options = podoco::AnalyzerOptions {
        compute_policy: podoco::options::ComputePolicy::CpuOnly,
        limits: podoco::ResourceLimits::new(
            1,
            16,
            1,
            100_000,
            100_000,
            128 * 1024 * 1024,
            48 * 1024 * 1024,
        )
        .unwrap(),
    };
    // SAFETY: Borrowed byte arrays and disjoint output scalars live for each call.
    unsafe {
        assert_eq!(
            podoco_formula_bundle_verify(bytes(&[0xff]), &mut output, &mut error),
            PODOCO_ERROR
        );
        assert_eq!(output, 0);
        assert_eq!(take_json(error)["code"], "invalid_input");
        for cap in [0u64, 2049, u64::MAX, 2048] {
            let config = serde_json::to_vec(&serde_json::json!({"schema_version": 0,
                "bundle_directory": "must-not-read", "options": options, "formula_options": cap}))
            .unwrap();
            assert_eq!(
                podoco_analyzer_open(bytes(&config), &mut output, &mut error),
                PODOCO_ERROR
            );
            assert_eq!(output, 0);
            assert_eq!(take_json(error)["code"], "invalid_input");
        }
    }
}

#[cfg(feature = "coreml")]
#[test]
#[ignore = "requires explicit verified M2 bundle; native C ABI job qualification"]
fn native_document_transport_and_cancellation() {
    use podoco::{
        Affine, AlphaMode, AnalysisOptions, AnalyzerOptions, DocumentRef, FormulaScope,
        ImageDescriptor, LayoutSession, ModelBundle, PageDescriptor, PageImage, PageInput, PageKey,
        PageSpace, PixelFormat, ProfileId, ResourceLimits, options::ComputePolicy,
    };
    let baseline = podoco_live_handles();
    let path = std::env::var("PODOCO_M2_BUNDLE").expect("bundle path");
    let bundle = ModelBundle::verify(&path).unwrap();
    let mut options = AnalysisOptions::new(ProfileId::new(&bundle.manifest().profile.id).unwrap());
    options.formula_scope = FormulaScope::None;
    let analyzer_options = AnalyzerOptions {
        compute_policy: ComputePolicy::CpuAndNeuralEngine,
        limits: ResourceLimits::new(1, 16, 2, 40000, 20000, 96_000_000, 1).unwrap(),
    };
    let document = DocumentRef::new("ffi-fixture", "1").unwrap();
    let pages: Vec<_> = (0..3)
        .map(|page_index| PageDescriptor {
            key: PageKey {
                document: document.clone(),
                page_index,
            },
            space: PageSpace::new(2., 2.).unwrap(),
        })
        .collect();
    let render = ProfileId::new("ffi-raw-v1").unwrap();
    let map = Affine::new([1., 0., 0., 1., 0., 0.]).unwrap();
    let input = |page: PageDescriptor| {
        PageInput::new(
            page,
            PageImage::copy(
                ImageDescriptor::new(2, 2, 8, PixelFormat::Rgba8, AlphaMode::Opaque).unwrap(),
                &[255; 16],
                16,
            )
            .unwrap(),
            map,
            render.clone(),
        )
        .unwrap()
    };
    let mut control = LayoutSession::open(bundle, analyzer_options.clone()).unwrap();
    let expected: Vec<_> = pages
        .iter()
        .map(|p| {
            serde_json::to_value(
                control
                    .analyze_page(input(p.clone()), options.clone())
                    .unwrap(),
            )
            .unwrap()
        })
        .collect();
    control.close().unwrap();
    let config = serde_json::to_vec(
        &serde_json::json!({"schema_version":0,"bundle_directory":path,"options":analyzer_options}),
    )
    .unwrap();
    let start=serde_json::to_vec(&serde_json::json!({"schema_version":0,"document":document,"pages":pages,"options":options})).unwrap();
    let (mut analyzer, mut job, mut error, mut output) = (0, 0, 0, 0);
    // SAFETY: Every borrowed JSON/pixel view and output scalar is live through
    // the synchronous call, with no writable aliases. No native callbacks here.
    unsafe {
        assert_eq!(
            podoco_analyzer_open(bytes(&config), &mut analyzer, &mut error),
            PODOCO_OK
        );
        assert_eq!(
            podoco_job_start(analyzer, bytes(&start), None, 0, &mut job, &mut error),
            PODOCO_OK
        );
        let mut seen = Vec::new();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(15);
        let outcome = loop {
            assert!(std::time::Instant::now() < deadline, "transport deadline");
            let status = podoco_source_next(job, &mut output, &mut error);
            assert_ne!(status, PODOCO_ERROR);
            if status == PODOCO_OK {
                let request = take_json(output);
                let mut image = 0;
                assert_eq!(
                    podoco_image_copy(&descriptor(), bytes(&[255; 16]), 16, &mut image, &mut error),
                    PODOCO_OK
                );
                let reply=serde_json::to_vec(&serde_json::json!({"schema_version":0,"page":request["page"],"pixel_to_page":map,"render_profile":render})).unwrap();
                assert_eq!(
                    podoco_source_reply(
                        job,
                        request["token"].as_u64().unwrap(),
                        image,
                        bytes(&reply),
                        &mut error
                    ),
                    PODOCO_OK
                );
                assert_eq!(podoco_release(image), PODOCO_OK);
            }
            let status = podoco_result_next(job, &mut output, &mut error);
            assert_ne!(status, PODOCO_ERROR);
            if status == PODOCO_OK {
                let update = take_json(output);
                let seq = update["sequence"].as_u64().unwrap();
                seen.push(update);
                assert_eq!(
                    podoco_result_ack(job, seq, PodocoBytes::default(), &mut error),
                    PODOCO_OK
                );
            }
            let status = podoco_job_outcome(job, &mut output, &mut error);
            assert_ne!(status, PODOCO_ERROR);
            if status == PODOCO_OK {
                break take_json(output);
            }
            std::thread::sleep(std::time::Duration::from_millis(1));
        };
        assert_eq!(seen.len(), 7);
        for (i, page) in expected.iter().enumerate() {
            assert_eq!(&seen[i * 2]["payload"]["page"], page);
            assert_eq!(&seen[i * 2 + 1]["payload"]["page"], page);
        }
        assert_eq!(outcome["outcome"]["status"], "completed");
        assert_eq!(outcome["outcome"]["delivered"]["updates_acknowledged"], 7);
        assert_eq!(podoco_job_close(job, &mut error), PODOCO_OK);
        assert_eq!(podoco_release(job), PODOCO_OK);
        // Abandon a live source rendezvous without a reply: final handle release
        // cancels/unblocks both native pumps rather than hanging forever.
        assert_eq!(
            podoco_job_start(analyzer, bytes(&start), None, 0, &mut job, &mut error),
            PODOCO_OK
        );
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while podoco_source_next(job, &mut output, &mut error) == PODOCO_PENDING {
            assert!(std::time::Instant::now() < deadline);
            std::thread::sleep(std::time::Duration::from_millis(1));
        }
        take_json(output);
        assert_eq!(podoco_release(job), PODOCO_OK);
        assert_eq!(podoco_analyzer_close(analyzer, &mut error), PODOCO_OK);
        assert_eq!(podoco_analyzer_close(analyzer, &mut error), PODOCO_OK);
        assert_eq!(podoco_release(analyzer), PODOCO_OK);
    }
    assert_eq!(podoco_live_handles(), baseline);
}
