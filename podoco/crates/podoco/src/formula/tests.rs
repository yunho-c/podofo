use super::*;
use crate::{
    AlphaMode, ImageDescriptor, PageImage, PixelFormat, domain::Sha256Digest, geometry::PixelCrop,
};
use std::{fs, path::PathBuf};

#[test]
fn crop_alpha_stride_and_limits() {
    let mut output = vec![0f32; preprocess::LEN];
    for (format, alpha, pixel, expected) in [
        (
            PixelFormat::Rgba8,
            AlphaMode::Straight,
            [10, 20, 30, 128],
            [132, 137, 142],
        ),
        (
            PixelFormat::Bgra8,
            AlphaMode::Straight,
            [30, 20, 10, 128],
            [132, 137, 142],
        ),
        (
            PixelFormat::Rgba8,
            AlphaMode::Premultiplied,
            [10, 20, 30, 128],
            [137, 147, 157],
        ),
        (
            PixelFormat::Rgba8,
            AlphaMode::Opaque,
            [10, 20, 30, 0],
            [10, 20, 30],
        ),
    ] {
        let mut bytes = vec![255u8; 48];
        bytes[20..24].copy_from_slice(&pixel);
        let image = PageImage::copy(
            ImageDescriptor::new(3, 3, 16, format, alpha).unwrap(),
            &bytes,
            48,
        )
        .unwrap();
        let crop = PixelCrop {
            left: 1,
            top: 1,
            right: 2,
            bottom: 2,
        };
        preprocess::run(&image, crop, &mut output, 2 * 1024 * 1024).unwrap();
        for (c, value) in expected.iter().enumerate() {
            let expected = (*value as f32 - 0.7931f32 * 255.) / (0.1738f32 * 255.);
            assert!(
                output[c * 768 * 768..(c + 1) * 768 * 768]
                    .iter()
                    .all(|&v| v == expected)
            );
        }
        assert_eq!(
            preprocess::run(&image, crop, &mut output, 1)
                .unwrap_err()
                .code,
            crate::ErrorCode::LimitExceeded
        );
    }
    assert!(FormulaOptions::new(0).is_err());
    assert!(FormulaOptions::new(2049).is_err());
    let cancel = FormulaCancellation::default();
    let other = cancel.clone();
    cancel.cancel();
    assert!(other.is_cancelled());
}

#[cfg(feature = "coreml")]
#[test]
#[ignore = "requires explicit formula bundle and captured pilot crops"]
fn native_cancellation_truncation_and_reuse() {
    use crate::{
        Affine, AnalyzerOptions, DocumentRef, PageDescriptor, PageInput, PageKey, PageSpace,
        ProfileId, Rect, RegionId, ResourceLimits,
        options::ComputePolicy,
        results::{FormulaDisplayKind, FormulaOutcome},
    };
    let root = PathBuf::from(std::env::var_os("PODOCO_M6_REFERENCE").expect("reference"));
    let reference: serde_json::Value =
        serde_json::from_slice(&fs::read(root.join("reference.json")).unwrap()).unwrap();
    let input = |id: &str| {
        let r = reference["images"]
            .as_array()
            .unwrap()
            .iter()
            .find(|r| r["id"] == id)
            .unwrap();
        let w = r["width"].as_u64().unwrap() as u32;
        let h = r["height"].as_u64().unwrap() as u32;
        let bytes = fs::read(root.join(format!("{id}.rgba"))).unwrap();
        let image = PageImage::copy(
            ImageDescriptor::new(
                w,
                h,
                u64::from(w) * 4,
                PixelFormat::Rgba8,
                AlphaMode::Straight,
            )
            .unwrap(),
            &bytes,
            bytes.len() as u64,
        )
        .unwrap();
        let page = PageInput::new(
            PageDescriptor {
                key: PageKey {
                    document: DocumentRef::new("test", "1").unwrap(),
                    page_index: 0,
                },
                space: PageSpace::new(f64::from(w), f64::from(h)).unwrap(),
            },
            image,
            Affine::new([1., 0., 0., 1., 0., 0.]).unwrap(),
            ProfileId::new("test").unwrap(),
        )
        .unwrap();
        FormulaInput {
            page,
            region_id: RegionId(1),
            bounds: Rect::new(0., 0., f64::from(w), f64::from(h)).unwrap(),
            display_kind: FormulaDisplayKind::Inline,
        }
    };
    let options = AnalyzerOptions {
        compute_policy: ComputePolicy::CpuOnly,
        limits: ResourceLimits::new(
            1,
            32 * 1024 * 1024,
            1,
            1024 * 1024,
            1024 * 1024,
            128 * 1024 * 1024,
            48 * 1024 * 1024,
        )
        .unwrap(),
    };
    let mut session = FormulaSession::open(
        FormulaBundle::verify(std::env::var_os("PODOCO_M6_BUNDLE").expect("bundle")).unwrap(),
        options,
    )
    .unwrap();
    let short = "0001125_page03-e020";
    let long = "0010212_page02-e023";
    let limited = session
        .recognize(
            input(short),
            FormulaOptions::new(1).unwrap(),
            FormulaCancellation::default(),
        )
        .unwrap();
    assert!(matches!(limited, FormulaOutcome::Truncated { .. }));
    let calls = std::sync::atomic::AtomicU32::new(0);
    let cancelled = session
        .recognize_with_cancel(
            input(long),
            FormulaOptions::default(),
            Box::new(move || calls.fetch_add(1, std::sync::atomic::Ordering::Relaxed) > 24),
        )
        .unwrap_err();
    assert_eq!(cancelled.code, crate::ErrorCode::Cancelled);
    assert!(!session.failed());
    let expected = reference["texts"]
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["id"] == short && r["run"] == "04-cpu")
        .unwrap();
    for _ in 0..2 {
        let result = session
            .recognize(
                input(short),
                FormulaOptions::default(),
                FormulaCancellation::default(),
            )
            .unwrap();
        assert!(
            matches!(result,FormulaOutcome::Recognized{formula} if formula.latex==expected["latex"].as_str().unwrap())
        );
        assert_eq!(
            session.stats().last_token_ids,
            serde_json::from_value::<Vec<u32>>(expected["ids"].clone()).unwrap()
        );
    }
    assert_eq!(session.stats().model_loads, 3);
    session.close().unwrap();
    session.close().unwrap();
    assert_eq!(
        session
            .recognize(
                input(short),
                FormulaOptions::default(),
                FormulaCancellation::default()
            )
            .unwrap_err()
            .code,
        crate::ErrorCode::InvalidInput
    );
}

#[test]
#[ignore = "requires explicit offline reference capture and formula bundle"]
fn portable_reference_parity() {
    let root = PathBuf::from(std::env::var_os("PODOCO_M6_REFERENCE").expect("reference"));
    let bundle =
        FormulaBundle::verify(std::env::var_os("PODOCO_M6_BUNDLE").expect("bundle")).unwrap();
    let reference: serde_json::Value =
        serde_json::from_slice(&fs::read(root.join("reference.json")).unwrap()).unwrap();
    let decoder =
        text::Decoder::load(&bundle.directory().join("checkpoint/tokenizer.json")).unwrap();
    for r in reference["texts"].as_array().unwrap() {
        let ids = serde_json::from_value::<Vec<u32>>(r["ids"].clone()).unwrap();
        let (raw, latex) = decoder.decode(&ids).unwrap();
        assert_eq!(
            raw,
            r["raw"].as_str().unwrap(),
            "{} {} raw",
            r["id"],
            r["run"]
        );
        assert_eq!(
            latex,
            r["latex"].as_str().unwrap(),
            "{} {} normalized",
            r["id"],
            r["run"]
        );
    }
    for r in reference["special"].as_array().unwrap() {
        assert_eq!(
            decoder.normalize(r["raw"].as_str().unwrap()).unwrap(),
            r["latex"].as_str().unwrap(),
            "{r}"
        );
    }
    use sha2::{Digest, Sha256};
    let mut hash = Sha256::new();
    let mut row = vec![0; 65536];
    for blue in 0..=255u8 {
        for red in 0..=255u8 {
            for green in 0..=255u8 {
                row[usize::from(red) * 256 + usize::from(green)] =
                    preprocess::gray_value([red, green, blue]);
            }
        }
        hash.update(&row);
    }
    assert_eq!(
        format!("{:x}", hash.finalize()),
        reference["rgb_grayscale_sha256"].as_str().unwrap()
    );
    let mut output = vec![0f32; preprocess::LEN];
    for r in reference["images"].as_array().unwrap() {
        let id = r["id"].as_str().unwrap();
        let w = r["width"].as_u64().unwrap() as u32;
        let h = r["height"].as_u64().unwrap() as u32;
        let rgba = fs::read(root.join(format!("{id}.rgba"))).unwrap();
        assert_eq!(
            Sha256Digest::of_bytes(&rgba).as_str(),
            r["rgba_sha256"].as_str().unwrap()
        );
        let image = PageImage::copy(
            ImageDescriptor::new(
                w,
                h,
                u64::from(w) * 4,
                PixelFormat::Rgba8,
                AlphaMode::Straight,
            )
            .unwrap(),
            &rgba,
            rgba.len() as u64,
        )
        .unwrap();
        preprocess::run(
            &image,
            PixelCrop {
                left: 0,
                top: 0,
                right: w,
                bottom: h,
            },
            &mut output,
            128 * 1024 * 1024,
        )
        .unwrap_or_else(|e| panic!("{id}: {e}"));
        let bytes: Vec<u8> = output.iter().flat_map(|v| v.to_le_bytes()).collect();
        if Sha256Digest::of_bytes(&bytes).as_str() != r["pixels_sha256"].as_str().unwrap() {
            let saved = root.join(format!("{id}.f32"));
            if let Ok(expected) = fs::read(saved) {
                let mismatches = bytes
                    .chunks_exact(4)
                    .zip(expected.chunks_exact(4))
                    .filter(|(a, b)| a != b)
                    .count();
                fs::write(root.join(format!("{id}-rust.f32")), &bytes).unwrap();
                panic!("preprocessing differs: {id}, {mismatches} values");
            }
            panic!("preprocessing hash differs: {id}");
        }
    }
}
