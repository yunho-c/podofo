//! Integer bicubic interpolation matching the pinned PyTorch uint8 CPU path.
//! Adapted from ATen UpSampleKernel.cpp / UpSample.h at 7661cd9c6b84.
//! See third_party/pytorch-LICENSE and docs/internal/m2-validation.md.
use crate::{AlphaMode, Error, PageImage, PixelFormat, Result};

pub(super) const SIDE: usize = 800;
pub(super) const INPUT_LEN: usize = 3 * SIDE * SIDE;

#[derive(Clone, Copy, Default)]
struct Tap {
    start: usize,
    len: usize,
    weights: [i32; 4],
}

fn cubic(x: f64) -> f64 {
    let x = x.abs();
    if x < 1.0 {
        ((1.25 * x - 2.25) * x) * x + 1.0
    } else if x < 2.0 {
        ((-0.75 * x + 3.75) * x - 6.0) * x + 3.0
    } else {
        0.0
    }
}

fn coefficients(size: usize, taps: &mut [Tap; SIDE]) -> u32 {
    let mut floats = [[0.0f64; 4]; SIDE];
    let mut maximum = 0.0f64;
    for (i, (tap, weights)) in taps.iter_mut().zip(&mut floats).enumerate() {
        let source = (size as f64 / SIDE as f64) * (i as f64 + 0.5) - 0.5;
        // The pinned C++ helper deliberately calls floorf even for double input.
        let index = ((source as f32).floor() as i64).min(size as i64 - 1);
        let lambda = (source - index as f64).clamp(0.0, 1.0);
        let begin = index - 1;
        tap.start = begin.max(0) as usize;
        tap.len = ((index + 3).min(size as i64) - tap.start as i64).clamp(0, 4) as usize;
        let mut dest = 0;
        for j in 0..4 {
            let sample = begin + j as i64;
            if sample <= 0 {
                dest = 0;
            } else if sample >= size as i64 - 1 {
                dest = tap.len - 1;
            }
            weights[dest] += cubic(j as f64 - 1.0 - lambda);
            maximum = maximum.max(weights[dest]);
            dest += 1;
        }
    }
    let precision = (0..22)
        .find(|p| (0.5 + maximum * f64::from(1u32 << (p + 1))) as i32 >= 32768)
        .unwrap_or(22);
    for (tap, weights) in taps.iter_mut().zip(floats) {
        for (dest, weight) in tap.weights.iter_mut().zip(weights) {
            // C++ truncation after adding signed 0.5, not ties-to-even.
            let value = weight * f64::from(1u32 << precision);
            *dest = (value + if value < 0.0 { -0.5 } else { 0.5 }) as i32;
        }
    }
    precision
}

fn composite(pixel: &[u8], channel: usize, alpha: AlphaMode) -> u8 {
    let color = u32::from(pixel[channel]);
    let a = u32::from(pixel[3]);
    match alpha {
        AlphaMode::Opaque => color as u8,
        AlphaMode::Straight => ((color * a + 255 * (255 - a) + 127) / 255) as u8,
        AlphaMode::Premultiplied => (color + 255 - a) as u8,
    }
}

/// Four horizontally resized rows; no full-resolution intermediate allocation.
pub(super) struct Preprocessor {
    horizontal: Box<[Tap; SIDE]>,
    vertical: Box<[Tap; SIDE]>,
    rows: Box<[[u8; SIDE * 3]; 4]>,
}
impl Preprocessor {
    pub(super) const BYTES: u64 = (2 * size_of::<[Tap; SIDE]>() + 4 * SIDE * 3) as u64;

    pub(super) fn new() -> Self {
        Self {
            horizontal: Box::new([Tap::default(); SIDE]),
            vertical: Box::new([Tap::default(); SIDE]),
            rows: Box::new([[0; SIDE * 3]; 4]),
        }
    }

    pub(super) fn run(&mut self, image: &PageImage, output: &mut [f32]) -> Result<()> {
        if output.len() != INPUT_LEN {
            return Err(Error::input("preprocessor output must be [1,3,800,800]"));
        }
        let d = image.descriptor();
        // Validate even pixels that downsampling will not visit.
        if d.alpha() == AlphaMode::Premultiplied {
            for y in 0..d.height() {
                if image
                    .row(y)
                    .expect("validated row")
                    .chunks_exact(4)
                    .any(|p| p[..3].iter().any(|c| *c > p[3]))
                {
                    return Err(Error::input("premultiplied color exceeds alpha"));
                }
            }
        }
        let channels = match d.format() {
            PixelFormat::Rgba8 => [0, 1, 2],
            PixelFormat::Bgra8 => [2, 1, 0],
        };
        let hp = coefficients(d.width() as usize, &mut self.horizontal);
        let vp = coefficients(d.height() as usize, &mut self.vertical);
        let mut cached = [usize::MAX; 4];
        for (y, vertical) in self.vertical.iter().enumerate() {
            for row_index in vertical.start..vertical.start + vertical.len {
                let slot = row_index % 4;
                if cached[slot] == row_index {
                    continue;
                }
                let source = image.row(row_index as u32).expect("validated row");
                for (x, tap) in self.horizontal.iter().enumerate() {
                    for (c, &channel) in channels.iter().enumerate() {
                        let mut value = 1 << (hp - 1);
                        for (j, &weight) in tap.weights[..tap.len].iter().enumerate() {
                            value += i32::from(composite(
                                &source[(tap.start + j) * 4..][..4],
                                channel,
                                d.alpha(),
                            )) * weight;
                        }
                        self.rows[slot][x * 3 + c] = (value >> hp).clamp(0, 255) as u8;
                    }
                }
                cached[slot] = row_index;
            }
            for x in 0..SIDE {
                for c in 0..3 {
                    let mut value = 1 << (vp - 1);
                    for (j, &weight) in vertical.weights[..vertical.len].iter().enumerate() {
                        value += i32::from(self.rows[(vertical.start + j) % 4][x * 3 + c]) * weight;
                    }
                    output[c * SIDE * SIDE + y * SIDE + x] =
                        ((value >> vp).clamp(0, 255) as f32) / 255.0;
                }
            }
        }
        Ok(())
    }
}
