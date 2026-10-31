use super::*;
use crate::{
    Affine, AlphaMode, DocumentRef, ImageDescriptor, PageDescriptor, PageImage, PageKey, PageSpace,
    PixelFormat, bundle::BundleManifest,
};

fn input(
    width: u32,
    height: u32,
    stride: u64,
    bytes: &[u8],
    format: PixelFormat,
    alpha: AlphaMode,
) -> PageInput {
    PageInput::new(
        PageDescriptor {
            key: PageKey {
                document: DocumentRef::new("fixture", "1").unwrap(),
                page_index: 0,
            },
            space: PageSpace::new(f64::from(width), f64::from(height)).unwrap(),
        },
        PageImage::copy(
            ImageDescriptor::new(width, height, stride, format, alpha).unwrap(),
            bytes,
            bytes.len() as u64,
        )
        .unwrap(),
        Affine::new([1., 0., 0., 1., 0., 0.]).unwrap(),
        ProfileId::new("test").unwrap(),
    )
    .unwrap()
}
fn manifest() -> BundleManifest {
    BundleManifest::parse(crate::bundle::PP_DOCLAYOUT_V3_V1_MANIFEST.as_bytes()).unwrap()
}
fn evidence() -> PipelineProvenance {
    let m = manifest();
    PipelineProvenance {
        sdk_version: ProfileId::new("test").unwrap(),
        backend: ProfileId::new("coreml").unwrap(),
        compute_policy: ComputePolicy::CpuOnly,
        adapter: ProfileId::new(m.profile.adapter).unwrap(),
        profile: ProfileId::new(m.profile.id).unwrap(),
        models: vec![ModelProvenance {
            model_id: ProfileId::new(m.id).unwrap(),
            manifest_sha256: crate::domain::Sha256Digest::of_bytes(b"test"),
            artifacts: [(
                "test".into(),
                crate::domain::Sha256Digest::of_bytes(b"test"),
            )]
            .into(),
        }],
    }
}
#[test]
fn pixels_cover_channels_padding_alpha_and_single_pixel_resize() {
    let mut pre = Preprocessor::new();
    let mut out = vec![0.; INPUT_LEN];
    for (format, bytes) in [
        (PixelFormat::Rgba8, [10, 20, 30, 128, 99, 99, 99, 99]),
        (PixelFormat::Bgra8, [30, 20, 10, 128, 99, 99, 99, 99]),
    ] {
        let page = input(1, 1, 8, &bytes, format, AlphaMode::Straight);
        pre.run(page.image(), &mut out).unwrap();
        assert!(out[..640000].iter().all(|&v| v == 132.0 / 255.0));
        assert!(out[640000..1280000].iter().all(|&v| v == 137.0 / 255.0));
        assert!(out[1280000..].iter().all(|&v| v == 142.0 / 255.0));
    }
    let invalid = input(
        1,
        1,
        4,
        &[129, 0, 0, 128],
        PixelFormat::Rgba8,
        AlphaMode::Premultiplied,
    );
    assert_eq!(
        pre.run(invalid.image(), &mut out).unwrap_err().code,
        ErrorCode::InvalidInput
    );
    let valid = input(
        1,
        1,
        4,
        &[10, 20, 30, 128],
        PixelFormat::Rgba8,
        AlphaMode::Premultiplied,
    );
    pre.run(valid.image(), &mut out).unwrap();
    assert_eq!(out[0], 137.0 / 255.0);
    let opaque = input(
        1,
        1,
        4,
        &[10, 20, 30, 0],
        PixelFormat::Rgba8,
        AlphaMode::Opaque,
    );
    pre.run(opaque.image(), &mut out).unwrap();
    assert_eq!(out[0], 10.0 / 255.0);
}

#[test]
fn decoding_preserves_pairs_ties_and_formula_context() {
    let page = input(1, 1, 4, &[255; 4], PixelFormat::Rgba8, AlphaMode::Opaque);
    let mut logits = vec![-100.; 7500];
    for i in [5, 15, 25 + 11, 50 + 17] {
        logits[i] = 1.;
    }
    let boxes = [0.5, 0.5, 2., 2.].repeat(300);
    let order = vec![0.; 90000];
    let result = decode(
        &manifest().profile,
        &page,
        &evidence(),
        &logits,
        &boxes,
        &order,
    )
    .unwrap();
    assert_eq!(
        result.regions.iter().map(|r| r.id.0).collect::<Vec<_>>(),
        [5, 15, 36, 67]
    );
    assert_eq!(result.formulas.len(), 2);
    assert_eq!(
        result.regions[0].bounds,
        Rect::new(-0.5, -0.5, 1.5, 1.5).unwrap()
    );
    assert_ne!(
        result.regions[0].display_kind,
        result.regions[1].display_kind
    );
    let rotated = PageInput::new(
        page.descriptor().clone(),
        page.image().clone(),
        Affine::new([0., 2., -3., 0., 9., 11.]).unwrap(),
        page.render_profile().clone(),
    )
    .unwrap();
    let mapped = decode(
        &manifest().profile,
        &rotated,
        &evidence(),
        &logits,
        &boxes,
        &order,
    )
    .unwrap();
    assert_eq!(
        mapped.regions[0].bounds,
        Rect::new(4.5, 10., 10.5, 14.).unwrap()
    );
    let mut invalid_boxes = boxes.clone();
    invalid_boxes[3] = 0.;
    assert_eq!(
        decode(
            &manifest().profile,
            &page,
            &evidence(),
            &logits,
            &invalid_boxes,
            &order
        )
        .unwrap_err()
        .code,
        ErrorCode::Layout
    );
    assert!(result.to_json(1).is_err());
    logits.fill(-100.);
    assert!(
        decode(
            &manifest().profile,
            &page,
            &evidence(),
            &logits,
            &boxes,
            &order
        )
        .unwrap()
        .regions
        .is_empty()
    );
    logits[0] = f32::NAN;
    assert!(
        decode(
            &manifest().profile,
            &page,
            &evidence(),
            &logits,
            &boxes,
            &order
        )
        .is_err()
    );
}

/// Disk exchange stays in this ignored test, never in the public inference API.
/// The Python runner writes original raw RGBA and pinned tensors/outputs, invokes
/// this test, then compares the Rust captures without adding a tensor-file API.
#[test]
#[ignore = "requires explicit local M2 qualification inputs"]
fn qualification_exchange() {
    let directory =
        std::path::PathBuf::from(std::env::var_os("PODOCO_M2_EXCHANGE").expect("exchange path"));
    let cases: serde_json::Value =
        serde_json::from_slice(&std::fs::read(directory.join("cases.json")).unwrap()).unwrap();
    let mut pre = Preprocessor::new();
    let mut output = vec![0.; INPUT_LEN];
    for case in cases.as_array().unwrap() {
        let name = case["id"].as_str().unwrap();
        let width = case["width"].as_u64().unwrap() as u32;
        let height = case["height"].as_u64().unwrap() as u32;
        let bytes = std::fs::read(directory.join(format!("{name}.rgba"))).unwrap();
        let mut page = input(
            width,
            height,
            u64::from(width) * 4,
            &bytes,
            PixelFormat::Rgba8,
            AlphaMode::Straight,
        );
        if let Some(map) = case.get("pixel_to_page") {
            page = PageInput::new(
                page.descriptor().clone(),
                page.image().clone(),
                serde_json::from_value(map.clone()).unwrap(),
                page.render_profile().clone(),
            )
            .unwrap();
        }
        pre.run(page.image(), &mut output).unwrap();
        let mut file =
            std::fs::File::create(directory.join(format!("{name}.rust-input.f32"))).unwrap();
        use std::io::Write;
        let mut file = std::io::BufWriter::new(&mut file);
        for v in &output {
            file.write_all(&v.to_le_bytes()).unwrap();
        }
        let load = |suffix: &str| {
            let bytes = std::fs::read(directory.join(format!("{name}.{suffix}.f32"))).unwrap();
            bytes
                .chunks_exact(4)
                .map(|v| f32::from_le_bytes(v.try_into().unwrap()))
                .collect::<Vec<_>>()
        };
        if directory.join(format!("{name}.logits.f32")).exists() {
            let decoded = decode(
                &manifest().profile,
                &page,
                &evidence(),
                &load("logits"),
                &load("pred_boxes"),
                &load("order_logits"),
            )
            .unwrap();
            std::fs::write(
                directory.join(format!("{name}.rust-decoded.json")),
                decoded.to_json(2_000_000).unwrap(),
            )
            .unwrap();
        }
    }
}

#[cfg(feature = "coreml")]
#[test]
#[ignore = "requires explicit local model and M2 qualification inputs"]
fn native_qualification_exchange() {
    use crate::{AnalyzerOptions, LayoutSessionStats, ResourceLimits};
    use std::{io::Write, time::Instant};
    let directory =
        std::path::PathBuf::from(std::env::var_os("PODOCO_M2_EXCHANGE").expect("exchange path"));
    let bundle_path = std::env::var_os("PODOCO_M2_BUNDLE").expect("bundle path");
    let policy_name = std::env::var("PODOCO_M2_POLICY").expect("policy");
    let policy = match policy_name.as_str() {
        "cpu" => ComputePolicy::CpuOnly,
        "cpu-ne" => ComputePolicy::CpuAndNeuralEngine,
        "all" => ComputePolicy::All,
        _ => panic!("unknown policy"),
    };
    let cases: serde_json::Value =
        serde_json::from_slice(&std::fs::read(directory.join("cases.json")).unwrap()).unwrap();
    let bundle = ModelBundle::verify(bundle_path).unwrap();
    crate::runtime::coreml::pool(|| {
        let start = Instant::now();
        let mut pipeline = Pipeline::open(
            &bundle,
            &AnalyzerOptions {
                compute_policy: policy,
                limits: ResourceLimits::new(1, 128_000_000, 1, 2_000_000, 2_000_000, 96_000_000, 1)
                    .unwrap(),
            },
        )
        .unwrap();
        // Qualification alone maps/scans masks; these timings are not normal
        // pipeline latency. The CLI records the production readback boundary.
        pipeline.native.scan_masks = true;
        let mut stats = LayoutSessionStats {
            model_loads: 1,
            open_seconds: start.elapsed().as_secs_f64(),
            ..Default::default()
        };
        let addresses = (
            pipeline.input.as_ptr(),
            pipeline.logits.as_ptr(),
            pipeline.boxes.as_ptr(),
            pipeline.order.as_ptr(),
        );
        let mut records = Vec::new();
        for case in cases.as_array().unwrap() {
            if !case
                .get("native_policies")
                .and_then(|v| v.as_array())
                .is_some_and(|policies| policies.iter().any(|v| v.as_str() == Some(&policy_name)))
            {
                continue;
            }
            let name = case["id"].as_str().unwrap();
            let w = case["width"].as_u64().unwrap() as u32;
            let h = case["height"].as_u64().unwrap() as u32;
            let bytes = std::fs::read(directory.join(format!("{name}.rgba"))).unwrap();
            let page = input(
                w,
                h,
                u64::from(w) * 4,
                &bytes,
                PixelFormat::Rgba8,
                AlphaMode::Straight,
            );
            for repeat in 0..2 {
                let result = pipeline.analyze(&page, &mut stats).unwrap();
                for (label, values) in [
                    ("logits", &pipeline.logits),
                    ("pred_boxes", &pipeline.boxes),
                    ("order_logits", &pipeline.order),
                ] {
                    let mut file = std::io::BufWriter::new(
                        std::fs::File::create(
                            directory
                                .join(format!("{name}.{policy_name}.rust-{repeat}.{label}.f32")),
                        )
                        .unwrap(),
                    );
                    for value in values {
                        file.write_all(&value.to_le_bytes()).unwrap();
                    }
                }
                std::fs::write(
                    directory.join(format!("{name}.{policy_name}.rust-{repeat}.json")),
                    result.to_json(2_000_000).unwrap(),
                )
                .unwrap();
                records.push(serde_json::json!({"id":name,"repeat":repeat,"stats":stats}));
                assert_eq!(
                    addresses,
                    (
                        pipeline.input.as_ptr(),
                        pipeline.logits.as_ptr(),
                        pipeline.boxes.as_ptr(),
                        pipeline.order.as_ptr()
                    )
                );
            }
        }
        assert!(
            !records.is_empty(),
            "no native qualification cases selected"
        );
        std::fs::write(
            directory.join(format!("{policy_name}.rust-native-report.json")),
            serde_json::to_vec_pretty(&records).unwrap(),
        )
        .unwrap();
    });
}
