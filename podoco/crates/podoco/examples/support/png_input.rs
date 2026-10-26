//! Caller-side PNG decoding shared by the layout examples.
use podoco::{
    Affine, AlphaMode, DocumentRef, ImageDescriptor, PageDescriptor, PageImage, PageInput, PageKey,
    PageSpace, PixelFormat, ProfileId,
};
use std::{error::Error, fs::File, io::BufReader, path::Path};

pub fn page(path: &Path, index: u32, limit: u64) -> Result<PageInput, Box<dyn Error>> {
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
    let rgba = match info.color_type {
        png::ColorType::Rgba => {
            decoded.truncate(info.buffer_size());
            decoded
        }
        png::ColorType::GrayscaleAlpha => {
            let mut rgba = Vec::with_capacity(usize::try_from(size)?);
            for p in decoded[..info.buffer_size()].chunks_exact(2) {
                rgba.extend_from_slice(&[p[0], p[0], p[0], p[1]]);
            }
            rgba
        }
        _ => return Err("PNG decoder did not produce eight-bit pixels with alpha".into()),
    };
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
