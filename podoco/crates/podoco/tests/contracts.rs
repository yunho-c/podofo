//! Portable domain, ownership, and wire-contract regression tests.
use podoco::{
    domain::{Score, validate_pages},
    geometry::PixelCrop,
    options::FormulaScope,
    results::*,
    *,
};
use serde_json::{Value, json};

fn fixtures() -> Vec<Value> {
    serde_json::from_str(include_str!("../../../tests/fixtures/domain/updates.json")).unwrap()
}
fn decode(value: &Value) -> Result<AnalysisUpdate> {
    AnalysisUpdate::from_json(&serde_json::to_vec(value).unwrap(), 100_000)
}

#[test]
fn geometry_round_trips_corners_for_all_rotations_and_crop_translation() {
    let transforms = [
        [2., 0., 0., 3., 10., 20.],
        [0., 2., -3., 0., 610., 20.],
        [-2., 0., 0., -3., 210., 620.],
        [0., -2., 3., 0., 10., 220.],
    ];
    let raster = Rect::new(0., 0., 100., 200.).unwrap();
    for coefficients in transforms {
        let map = Affine::new(coefficients).unwrap();
        for corner in raster.corners() {
            let back = map
                .inverse()
                .unwrap()
                .map(map.map(corner).unwrap())
                .unwrap();
            assert!((back.x() - corner.x()).abs() < 1e-10);
            assert!((back.y() - corner.y()).abs() < 1e-10);
        }
        let page_bounds = map.map_rect(raster).unwrap();
        assert_eq!(
            map.crop_pixels(page_bounds, 100, 200).unwrap(),
            PixelCrop {
                left: 0,
                top: 0,
                right: 100,
                bottom: 200
            }
        );
    }
    let cropped = Affine::new([2., 0., 0., 2., 10., 20.]).unwrap();
    assert_eq!(
        cropped
            .crop_pixels(Rect::new(11., 21., 15., 25.).unwrap(), 100, 200)
            .unwrap(),
        PixelCrop {
            left: 0,
            top: 0,
            right: 3,
            bottom: 3
        }
    );
    assert!(
        cropped
            .crop_pixels(Rect::new(-20., -20., 0., 0.).unwrap(), 100, 200)
            .is_err()
    );
}

#[test]
fn invalid_geometry_cannot_enter_through_constructors_or_json() {
    assert!(PageSpace::new(0., 1.).is_err());
    assert!(Point::new(f64::NAN, 0.).is_err());
    assert!(Rect::new(1., 0., 0., 1.).is_err());
    assert!(Rect::new(-f64::MAX, 0., f64::MAX, 1.).is_err());
    assert!(Affine::new([1., 2., 2., 4., 0., 0.]).is_err());
    assert!(Affine::new([1., 0., 0., 1., f64::INFINITY, 0.]).is_err());
    assert!(serde_json::from_str::<PageSpace>("[-1,10]").is_err());
    assert!(serde_json::from_str::<Affine>("[0,0,0,0,0,0]").is_err());
    assert!(Polygon::new(vec![Point::new(0., 0.).unwrap(); 3]).is_err());
    assert!(Score::new(f64::NAN).is_err());
    assert_eq!(Score::new(-3.).unwrap().value(), -3.); // Scores are not forced into probability semantics.
}

#[test]
fn identities_and_page_subsets_preserve_revision_and_order() {
    assert!(DocumentRef::new(" ", "r").is_err());
    let document = DocumentRef::new("paper:한글", "revision-A").unwrap();
    let page = |page_index| PageDescriptor {
        key: PageKey {
            document: document.clone(),
            page_index,
        },
        space: PageSpace::new(100., 200.).unwrap(),
    };
    validate_pages(&document, &[page(7), page(2)]).unwrap();
    assert!(validate_pages(&document, &[page(7), page(7)]).is_err());
    let mut changed = page(1);
    changed.key.document = DocumentRef::new("paper:한글", "revision-B").unwrap();
    assert!(validate_pages(&document, &[changed]).is_err());
}

#[test]
fn copied_images_are_independent_and_account_for_padding_and_trailing_bytes() {
    for format in [PixelFormat::Bgra8, PixelFormat::Rgba8] {
        for alpha in [
            AlphaMode::Opaque,
            AlphaMode::Straight,
            AlphaMode::Premultiplied,
        ] {
            let descriptor = ImageDescriptor::new(2, 2, 12, format, alpha).unwrap();
            assert_eq!(descriptor.required_bytes(), 20);
            let mut source: Vec<u8> = (0..32).collect();
            let image = PageImage::copy(descriptor, &source, 32).unwrap();
            source.fill(0);
            assert_eq!(image.row(1).unwrap(), &[12, 13, 14, 15, 16, 17, 18, 19]);
            assert_eq!(image.retained_bytes(), 32);
            assert_eq!(image.descriptor().alpha(), alpha);
            assert!(image.row(2).is_none());
            assert_eq!(
                PageImage::copy(descriptor, &source, 31).unwrap_err().code,
                ErrorCode::LimitExceeded
            );
            assert!(PageImage::copy(descriptor, &source[..19], 32).is_err());
        }
    }
    assert!(ImageDescriptor::new(2, 1, 7, PixelFormat::Bgra8, AlphaMode::Opaque).is_err());
    assert!(ImageDescriptor::new(1, 2, u64::MAX, PixelFormat::Bgra8, AlphaMode::Opaque).is_err());
    assert!(ImageDescriptor::new(0, 1, 4, PixelFormat::Bgra8, AlphaMode::Opaque).is_err());
}

#[test]
fn page_input_rejection_returns_image() {
    let descriptor = ImageDescriptor::new(2, 1, 8, PixelFormat::Bgra8, AlphaMode::Opaque).unwrap();
    let image = PageImage::copy(descriptor, &[7; 8], 8).unwrap();
    let page = PageDescriptor {
        key: PageKey {
            document: DocumentRef::new("d", "r").unwrap(),
            page_index: 0,
        },
        space: PageSpace::new(1., 1.).unwrap(),
    };
    let enormous = Affine::new([f64::MAX, 0., 0., 1., 0., 0.]).unwrap();
    let rejected =
        PageInput::new(page, image, enormous, ProfileId::new("render").unwrap()).unwrap_err();
    assert_eq!(rejected.image.row(0).unwrap(), &[7; 8]);
}

#[test]
fn capabilities_reject_recognition_before_any_source_exists() {
    let capabilities = Capabilities {
        layout: true,
        formula_recognition: false,
        polygons: false,
        reading_order: true,
    };
    let mut options = AnalysisOptions::new(ProfileId::new("profile").unwrap());
    assert_eq!(
        capabilities.validate(&options).unwrap_err().code,
        ErrorCode::UnsupportedCapability
    );
    options.formula_scope = FormulaScope::None;
    capabilities.validate(&options).unwrap();
    options.require_polygons = true;
    assert!(capabilities.validate(&options).is_err());
    assert!(ResourceLimits::new(1, 100, 1, 100, 101, 1, 1).is_err());
    assert!(ResourceLimits::new(1, 100, 0, 100, 100, 1, 1).is_err());
    let limits = ResourceLimits::new(1, 100, 1, 100, 100, 1, 1).unwrap();
    assert_eq!(
        serde_json::from_slice::<ResourceLimits>(&serde_json::to_vec(&limits).unwrap()).unwrap(),
        limits
    );
}

#[test]
fn every_schema_fixture_round_trips_without_latex_or_metadata_rewriting() {
    let cases = fixtures();
    assert_eq!(cases.len(), 14);
    for fixture in cases {
        let update = decode(&fixture).unwrap();
        let bytes = update.to_json(100_000).unwrap();
        assert_eq!(serde_json::from_slice::<Value>(&bytes).unwrap(), fixture);
        assert_eq!(
            AnalysisUpdate::from_json(&bytes, bytes.len()).unwrap(),
            update
        );
        assert_eq!(
            update.to_json(bytes.len() - 1).unwrap_err().code,
            ErrorCode::LimitExceeded
        );
        assert_eq!(
            AnalysisUpdate::from_json(&bytes, bytes.len() - 1)
                .unwrap_err()
                .code,
            ErrorCode::LimitExceeded
        );
    }
}

#[test]
fn schema_evolution_and_invalid_states_fail_explicitly() {
    let baseline = fixtures().remove(0);
    let mut value = baseline.clone();
    value["optional_future_metadata"] = json!({"value":123});
    value["payload"]["page"]["future_field"] = json!(true);
    decode(&value).unwrap();
    value["schema_version"] = json!(1);
    assert_eq!(
        decode(&value).unwrap_err().code,
        ErrorCode::UnsupportedSchema
    );
    value = baseline.clone();
    value["payload"]["type"] = json!("future_required_operation");
    assert_eq!(
        decode(&value).unwrap_err().code,
        ErrorCode::UnsupportedSchema
    );
    value = baseline.clone();
    value["payload"]["page"]["regions"][0]["bounds"] = json!([1, 0, 0, 10]);
    assert!(decode(&value).is_err());
    value = baseline.clone();
    value["payload"]["page"]["formulas"][0]["region_id"] = json!(999);
    assert!(decode(&value).is_err());
    value = baseline.clone();
    value["payload"]["page"]["reading_order"]["region_ids"] = json!([0, 0]);
    assert!(decode(&value).is_err());
    value = baseline.clone();
    value["payload"]["page"]["page"]["key"]["document"]["revision"] = json!("changed");
    assert!(decode(&value).is_err());
    value = baseline;
    value["payload"]["type"] = json!("page_finished");
    assert!(decode(&value).is_err()); // Pending formulas cannot masquerade as final results.
}

#[test]
fn unknown_native_category_and_missing_score_remain_explicit() {
    let mut value = fixtures().remove(7); // layout only
    let region = &mut value["payload"]["page"]["regions"][0];
    region["category"] = json!("other");
    region["model_class_id"] = json!(987);
    region["model_label"] = json!("future-label");
    region["display_kind"] = Value::Null;
    value["payload"]["page"]["formulas"] = json!([]);
    let update = decode(&value).unwrap();
    let UpdatePayload::PageLayoutReady { page } = update.payload() else {
        panic!()
    };
    assert_eq!(page.regions[0].category, RegionCategory::Other);
    assert_eq!(page.regions[0].model_label, "future-label");
    assert!(page.regions[0].score.is_none());
}

#[test]
fn summary_and_recognition_invariants_are_validated_during_decoding() {
    let mut value = fixtures().remove(10);
    value["payload"]["summary"]["counts"]["formulas_failed"] = json!(1);
    assert!(decode(&value).is_err());
    value["payload"]["summary"]["counts"]["formulas_detected"] = json!(2);
    assert!(decode(&value).is_err()); // completed cannot contain failures
    let mut value = fixtures().remove(1);
    value["payload"]["outcome"]["formula"]["latex"] = json!(" ");
    assert!(decode(&value).is_err());
}
