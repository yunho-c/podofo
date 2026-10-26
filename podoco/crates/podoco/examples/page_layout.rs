//! PNG decoding belongs to the caller; the library accepts checked raw pixels.
use podoco::{
    Affine, AlphaMode, AnalysisOptions, AnalyzerOptions, DocumentRef, FormulaScope,
    ImageDescriptor, LayoutSession, ModelBundle, PageDescriptor, PageImage, PageInput, PageKey,
    PageSpace, PixelFormat, ProfileId, ResourceLimits, options::ComputePolicy,
};
use std::{
    error::Error,
    fs::File,
    io::{BufReader, Write},
    path::Path,
};

fn page(path: &Path, index: u32, limit: u64) -> Result<PageInput, Box<dyn Error>> {
    let mut decoder = png::Decoder::new(BufReader::new(File::open(path)?));
    decoder.set_limits(png::Limits {
        bytes: usize::try_from(limit)?,
    });
    decoder.set_transformations(
        png::Transformations::EXPAND | png::Transformations::STRIP_16 | png::Transformations::ALPHA,
    );
    let mut reader = decoder.read_info()?;
    let (width, height) = (reader.info().width, reader.info().height);
    let size = u64::from(width)
        .checked_mul(u64::from(height))
        .and_then(|n| n.checked_mul(4))
        .ok_or("PNG size overflow")?;
    if size > limit {
        return Err("PNG pixels exceed input budget".into());
    }
    let mut decoded = vec![0; reader.output_buffer_size().ok_or("PNG size overflow")?];
    let info = reader.next_frame(&mut decoded)?;
    let mut rgba = Vec::with_capacity(usize::try_from(size)?);
    match info.color_type {
        png::ColorType::Rgba => rgba.extend_from_slice(&decoded[..info.buffer_size()]),
        png::ColorType::GrayscaleAlpha => {
            for p in decoded[..info.buffer_size()].chunks_exact(2) {
                rgba.extend_from_slice(&[p[0], p[0], p[0], p[1]]);
            }
        }
        _ => return Err("PNG decoder did not produce eight-bit pixels with alpha".into()),
    }
    let image = PageImage::copy(
        ImageDescriptor::new(
            width,
            height,
            u64::from(width) * 4,
            PixelFormat::Rgba8,
            AlphaMode::Straight,
        )?,
        &rgba,
        limit,
    )?;
    PageInput::new(
        PageDescriptor {
            key: PageKey {
                document: DocumentRef::new("png-sequence", "1")?,
                page_index: index,
            },
            space: PageSpace::new(f64::from(width), f64::from(height))?,
        },
        image,
        Affine::new([1., 0., 0., 1., 0., 0.])?,
        ProfileId::new("png-pixel-space-v1")?,
    )
    .map_err(|e| e.error.into())
}

fn main() -> Result<(), Box<dyn Error>> {
    let args: Vec<_> = std::env::args().skip(1).collect();
    let [
        bundle,
        policy,
        input_bytes,
        tensor_bytes,
        result_bytes,
        pages @ ..,
    ] = args.as_slice()
    else {
        return Err("usage: page_layout BUNDLE cpu|cpu-ne|all INPUT_BYTES TENSOR_BYTES RESULT_BYTES PAGE.png [PAGE.png ...]".into());
    };
    if pages.is_empty() {
        return Err("at least one PNG page is required".into());
    }
    let policy = match policy.as_str() {
        "cpu" => ComputePolicy::CpuOnly,
        "cpu-ne" => ComputePolicy::CpuAndNeuralEngine,
        "all" => ComputePolicy::All,
        _ => return Err("compute policy must be cpu, cpu-ne, or all".into()),
    };
    let input_bytes: u64 = input_bytes.parse()?;
    let result_bytes: u64 = result_bytes.parse()?;
    let start = std::time::Instant::now();
    let bundle = ModelBundle::verify(bundle)?;
    let verification_seconds = start.elapsed().as_secs_f64();
    let mut options = AnalysisOptions::new(ProfileId::new(&bundle.manifest().profile.id)?);
    options.formula_scope = FormulaScope::None;
    let mut session = LayoutSession::open(
        bundle,
        AnalyzerOptions {
            compute_policy: policy,
            limits: ResourceLimits::new(
                1,
                input_bytes,
                1,
                result_bytes,
                result_bytes,
                tensor_bytes.parse()?,
                1,
            )?,
        },
    )?;
    let stdout = std::io::stdout();
    let mut stdout = stdout.lock();
    let mut measurements = Vec::new();
    for (index, path) in pages.iter().enumerate() {
        let result = session.analyze_page(
            page(Path::new(path), u32::try_from(index)?, input_bytes)?,
            options.clone(),
        )?;
        stdout.write_all(&result.to_json(usize::try_from(result_bytes)?)?)?;
        stdout.write_all(b"\n")?;
        measurements.push(session.stats());
    }
    session.close()?;
    eprintln!(
        "{}",
        serde_json::to_string(
            &serde_json::json!({"verification_seconds":verification_seconds,"pages":measurements})
        )?
    );
    Ok(())
}
