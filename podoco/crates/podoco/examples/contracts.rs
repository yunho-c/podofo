//! Construct a copied page input and serialize an explicit source failure, without inference.
use podoco::{results::UpdatePayload, *};

fn main() -> Result<()> {
    let document = DocumentRef::new("reader-document", "revision-1")?;
    let key = PageKey {
        document: document.clone(),
        page_index: 0,
    };
    let descriptor = ImageDescriptor::new(2, 2, 8, PixelFormat::Bgra8, AlphaMode::Opaque)?;
    let mut rendered = [255u8; 16];
    let image = PageImage::copy(descriptor, &rendered, 16)?;
    rendered.fill(0); // The SDK copy is already independent.
    assert_eq!(image.row(0), Some([255u8; 8].as_slice()));
    let input = PageInput::new(
        PageDescriptor {
            key: key.clone(),
            space: PageSpace::new(100., 100.)?,
        },
        image,
        Affine::new([50., 0., 0., 50., 0., 0.])?,
        ProfileId::new("opaque-white-no-annotations-v0")?,
    )
    .map_err(|rejected| rejected.error)?;
    println!("Retained image bytes: {}", input.image().retained_bytes());

    // An illustrative source failure, not a fabricated model prediction.
    let update = AnalysisUpdate::new(
        AnalysisId::new("example-analysis")?,
        document,
        0,
        UpdatePayload::PageFailed {
            page_key: key,
            error: Error::new(ErrorCode::PageSource, "Example: no renderer attached"),
        },
    )?;
    let json = update.to_json(4096)?;
    assert_eq!(AnalysisUpdate::from_json(&json, 4096)?, update);
    println!("{}", String::from_utf8_lossy(&json));
    Ok(())
}
