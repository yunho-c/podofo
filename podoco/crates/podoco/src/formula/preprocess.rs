//! Streaming reproduction of Transformers 5.8.1's formula image processor.
//! Antialiased integer weights follow PyTorch 7661cd9c6b84 UpSampleKernel.cpp;
//! see third_party/pytorch-LICENSE. Every pass rounds/clamps in uint8 space.
use crate::{AlphaMode, Error, ErrorCode, PageImage, PixelFormat, Result, geometry::PixelCrop};

pub(crate) const SIDE: usize = 768;
pub(crate) const LEN: usize = 3 * SIDE * SIDE;

pub(super) fn gray_value(rgb: [u8; 3]) -> u8 {
    let [r, g, b] = rgb.map(f32::from);
    // Torch's add_(other, alpha=...) uses FMA after the initial F32 multiply.
    b.mul_add(0.114, g.mul_add(0.587, r * 0.2989)) as u8
}

struct Budget {
    used: u64,
    limit: u64,
}
impl Budget {
    fn charge(&mut self, bytes: usize) -> Result<()> {
        self.used = self.used.checked_add(bytes as u64).ok_or_else(limit)?;
        if self.used > self.limit {
            return Err(limit());
        }
        Ok(())
    }
}
fn limit() -> Error {
    Error::new(
        ErrorCode::LimitExceeded,
        "formula preprocessing exceeds tensor budget",
    )
}
trait Rows {
    fn width(&self) -> usize;
    fn height(&self) -> usize;
    fn row(&mut self, y: usize, out: &mut [u8]);
}
struct Pixels<'a> {
    image: &'a PageImage,
    crop: PixelCrop,
}
impl Pixels<'_> {
    fn rgb(&self, x: usize, y: usize) -> [u8; 3] {
        let d = self.image.descriptor();
        let row = self
            .image
            .row(y as u32 + self.crop.top)
            .expect("checked crop");
        let pixel = &row[(x + self.crop.left as usize) * 4..][..4];
        let channels = if d.format() == PixelFormat::Rgba8 {
            [0, 1, 2]
        } else {
            [2, 1, 0]
        };
        channels.map(|c| {
            let color = u32::from(pixel[c]);
            let a = u32::from(pixel[3]);
            match d.alpha() {
                AlphaMode::Opaque => color as u8,
                AlphaMode::Straight => ((color * a + 255 * (255 - a) + 127) / 255) as u8,
                AlphaMode::Premultiplied => (color + 255 - a) as u8,
            }
        })
    }
    fn gray(&self, x: usize, y: usize) -> u8 {
        gray_value(self.rgb(x, y))
    }
    fn crop_margin(&mut self) {
        let (mut low, mut high) = (255u8, 0u8);
        for y in 0..self.height() {
            for x in 0..self.width() {
                let v = self.gray(x, y);
                low = low.min(v);
                high = high.max(v);
            }
        }
        if low == high {
            return;
        }
        let (mut l, mut t, mut r, mut b) = (self.width(), self.height(), 0, 0);
        for y in 0..self.height() {
            for x in 0..self.width() {
                if f32::from(self.gray(x, y) - low) / f32::from(high - low) * 255. < 200. {
                    l = l.min(x);
                    t = t.min(y);
                    r = r.max(x + 1);
                    b = b.max(y + 1);
                }
            }
        }
        self.crop.right = self.crop.left + r as u32;
        self.crop.bottom = self.crop.top + b as u32;
        self.crop.left += l as u32;
        self.crop.top += t as u32;
    }
}
impl Rows for Pixels<'_> {
    fn width(&self) -> usize {
        (self.crop.right - self.crop.left) as usize
    }
    fn height(&self) -> usize {
        (self.crop.bottom - self.crop.top) as usize
    }
    fn row(&mut self, y: usize, out: &mut [u8]) {
        for (x, pixel) in out.chunks_exact_mut(3).enumerate() {
            pixel.copy_from_slice(&self.rgb(x, y));
        }
    }
}
struct Tap {
    start: usize,
    weights: Vec<i32>,
}
struct Axis {
    taps: Vec<Tap>,
    precision: u32,
}
impl Axis {
    fn new(input: usize, output: usize, cubic: bool, budget: &mut Budget) -> Result<Self> {
        let scale = input as f64 / output as f64;
        let support = if cubic { 2. } else { 1. } * scale.max(1.);
        let max_taps = ((support.ceil() as usize)
            .checked_mul(2)
            .and_then(|v| v.checked_add(1)))
        .ok_or_else(limit)?;
        // Account vector headers and peak float/integer coefficient storage before allocation.
        let count = output.checked_mul(max_taps).ok_or_else(limit)?;
        budget.charge(
            count
                .checked_mul(12)
                .and_then(|v| v.checked_add(output * 64))
                .ok_or_else(limit)?,
        )?;
        let mut floats = Vec::with_capacity(output);
        let mut maximum = 0.0f64;
        for i in 0..output {
            let center = scale * (i as f64 + 0.5);
            let start = ((center - support + 0.5) as i64).max(0) as usize;
            let end = (((center + support + 0.5) as usize).min(input)).min(start + max_taps);
            let mut weights = Vec::with_capacity(end - start);
            for j in start..end {
                let x = ((j as f64 - center + 0.5) / scale.max(1.)).abs();
                let w = if cubic {
                    if x < 1. {
                        ((1.5 * x - 2.5) * x) * x + 1.
                    } else if x < 2. {
                        ((-0.5 * x + 2.5) * x - 4.) * x + 2.
                    } else {
                        0.
                    }
                } else {
                    (1. - x).max(0.)
                };
                weights.push(w);
            }
            let sum: f64 = weights.iter().sum();
            for w in &mut weights {
                *w /= sum;
                maximum = maximum.max(*w);
            }
            floats.push((start, weights));
        }
        let precision = (0..22)
            .find(|p| (0.5 + maximum * f64::from(1u32 << (p + 1))) as i32 >= 32768)
            .unwrap_or(22);
        let taps = floats
            .into_iter()
            .map(|(start, weights)| Tap {
                start,
                weights: weights
                    .into_iter()
                    .map(|w| {
                        let v = w * f64::from(1u32 << precision);
                        (v + if v < 0. { -0.5 } else { 0.5 }) as i32
                    })
                    .collect(),
            })
            .collect();
        Ok(Self { taps, precision })
    }
}
struct Resize<'a> {
    source: Box<dyn Rows + 'a>,
    horizontal: Axis,
    vertical: Axis,
    source_row: Vec<u8>,
    horizontal_row: Vec<u8>,
    accum: Vec<i64>,
    last_y: usize,
}
impl<'a> Resize<'a> {
    fn with_source(
        source: Box<dyn Rows + 'a>,
        w: usize,
        h: usize,
        cubic: bool,
        budget: &mut Budget,
    ) -> Result<Box<dyn Rows + 'a>> {
        if w == 0 || h == 0 {
            return Err(Error::input(
                "formula aspect ratio yields an empty thumbnail",
            ));
        }
        if w == source.width() && h == source.height() {
            return Ok(source);
        }
        budget.charge(
            source
                .width()
                .checked_mul(3)
                .and_then(|v| v.checked_add(w * 27))
                .ok_or_else(limit)?,
        )?;
        let horizontal = Axis::new(source.width(), w, cubic, budget)?;
        let vertical = Axis::new(source.height(), h, cubic, budget)?;
        Ok(Box::new(Self {
            source_row: vec![0; source.width() * 3],
            horizontal_row: vec![0; w * 3],
            accum: vec![0; w * 3],
            source,
            horizontal,
            vertical,
            last_y: usize::MAX,
        }))
    }
}
impl Rows for Resize<'_> {
    fn width(&self) -> usize {
        self.horizontal.taps.len()
    }
    fn height(&self) -> usize {
        self.vertical.taps.len()
    }
    fn row(&mut self, y: usize, out: &mut [u8]) {
        let tap = &self.vertical.taps[y];
        self.accum.fill(1i64 << (self.vertical.precision - 1));
        for (j, &weight) in tap.weights.iter().enumerate() {
            let sy = tap.start + j;
            if sy != self.last_y {
                self.source.row(sy, &mut self.source_row);
                for (x, t) in self.horizontal.taps.iter().enumerate() {
                    for c in 0..3 {
                        let mut sum = 1i64 << (self.horizontal.precision - 1);
                        for (i, &w) in t.weights.iter().enumerate() {
                            sum += i64::from(w) * i64::from(self.source_row[(t.start + i) * 3 + c]);
                        }
                        self.horizontal_row[x * 3 + c] =
                            (sum >> self.horizontal.precision).clamp(0, 255) as u8;
                    }
                }
                self.last_y = sy;
            }
            for (v, &p) in self.accum.iter_mut().zip(&self.horizontal_row) {
                *v += i64::from(weight) * i64::from(p);
            }
        }
        for (v, &s) in out.iter_mut().zip(&self.accum) {
            *v = (s >> self.vertical.precision).clamp(0, 255) as u8;
        }
    }
}

/// Returns conservatively charged temporary bytes; the caller owns output storage.
pub(crate) fn run(
    image: &PageImage,
    crop: PixelCrop,
    output: &mut [f32],
    scratch_limit: u64,
) -> Result<u64> {
    let d = image.descriptor();
    if crop.left >= crop.right
        || crop.top >= crop.bottom
        || crop.right > d.width()
        || crop.bottom > d.height()
        || output.len() != LEN
    {
        return Err(Error::input("invalid formula raster crop or output shape"));
    }
    if d.alpha() == AlphaMode::Premultiplied {
        for y in crop.top..crop.bottom {
            if image.row(y).expect("checked row")[crop.left as usize * 4..crop.right as usize * 4]
                .chunks_exact(4)
                .any(|p| p[..3].iter().any(|&c| c > p[3]))
            {
                return Err(Error::input("premultiplied color exceeds alpha"));
            }
        }
    }
    let mut source = Pixels { image, crop };
    source.crop_margin();
    let (w, h) = (source.width(), source.height());
    let (rw, rh) = if w < h {
        (SIDE, h.checked_mul(SIDE).ok_or_else(limit)? / w)
    } else {
        (w.checked_mul(SIDE).ok_or_else(limit)? / h, SIDE)
    };
    let (tw, th) = if rw > rh {
        (SIDE, rh * SIDE / rw)
    } else if rh > rw {
        (rw * SIDE / rh, SIDE)
    } else {
        (SIDE, SIDE)
    };
    let mut budget = Budget {
        used: 0,
        limit: scratch_limit,
    };
    let first = Resize::with_source(Box::new(source), rw, rh, false, &mut budget)?;
    let mut second = Resize::with_source(first, tw, th, true, &mut budget)?;
    budget.charge(tw * 3)?;
    let mut row = vec![0; tw * 3];
    let mean = 0.7931f32 * 255.;
    let std = 0.1738f32 * 255.;
    output.fill(-mean / std);
    for y in 0..th {
        second.row(y, &mut row);
        for x in 0..tw {
            for c in 0..3 {
                output[c * SIDE * SIDE + (y + (SIDE - th) / 2) * SIDE + x + (SIDE - tw) / 2] =
                    (f32::from(row[x * 3 + c]) - mean) / std;
            }
        }
    }
    Ok(budget.used)
}
