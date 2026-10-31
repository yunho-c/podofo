//! Canonical top-left, y-down page geometry and pixel-edge mappings.
use crate::{Error, Result};
use serde::{Deserialize, Serialize};

fn finite(values: &[f64]) -> Result<()> {
    if values.iter().all(|v| v.is_finite()) {
        Ok(())
    } else {
        Err(Error::input("geometry must be finite"))
    }
}

/// A finite point in page or pixel-edge coordinates.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(try_from = "[f64; 2]", into = "[f64; 2]")]
pub struct Point {
    x: f64,
    y: f64,
}
impl Point {
    /// Validate and construct a point.
    pub fn new(x: f64, y: f64) -> Result<Self> {
        finite(&[x, y])?;
        Ok(Self { x, y })
    }
    /// Horizontal coordinate.
    pub fn x(self) -> f64 {
        self.x
    }
    /// Vertical coordinate.
    pub fn y(self) -> f64 {
        self.y
    }
}
impl TryFrom<[f64; 2]> for Point {
    type Error = Error;
    fn try_from(v: [f64; 2]) -> Result<Self> {
        Self::new(v[0], v[1])
    }
}
impl From<Point> for [f64; 2] {
    fn from(v: Point) -> Self {
        [v.x, v.y]
    }
}

/// Positive finite logical page dimensions; PDF callers use points.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(try_from = "[f64; 2]", into = "[f64; 2]")]
pub struct PageSpace {
    width: f64,
    height: f64,
}
impl PageSpace {
    /// Validate positive dimensions.
    pub fn new(width: f64, height: f64) -> Result<Self> {
        finite(&[width, height])?;
        if width <= 0.0 || height <= 0.0 {
            return Err(Error::input("page dimensions must be positive"));
        }
        Ok(Self { width, height })
    }
    /// Logical page width.
    pub fn width(self) -> f64 {
        self.width
    }
    /// Logical page height.
    pub fn height(self) -> f64 {
        self.height
    }
}
impl TryFrom<[f64; 2]> for PageSpace {
    type Error = Error;
    fn try_from(v: [f64; 2]) -> Result<Self> {
        Self::new(v[0], v[1])
    }
}
impl From<PageSpace> for [f64; 2] {
    fn from(v: PageSpace) -> Self {
        [v.width, v.height]
    }
}

/// A nonempty finite rectangle, serialized as `[left, top, right, bottom]`.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(try_from = "[f64; 4]", into = "[f64; 4]")]
pub struct Rect {
    edges: [f64; 4],
}
impl Rect {
    /// Construct continuous bounds; negative origins are permitted.
    pub fn new(left: f64, top: f64, right: f64, bottom: f64) -> Result<Self> {
        finite(&[left, top, right, bottom, right - left, bottom - top])?;
        if right <= left || bottom <= top {
            return Err(Error::input("rectangle must have positive area"));
        }
        Ok(Self {
            edges: [left, top, right, bottom],
        })
    }
    /// Bounds in left/top/right/bottom order.
    pub fn edges(self) -> [f64; 4] {
        self.edges
    }
    /// Clockwise corner order beginning at top left.
    pub fn corners(self) -> [Point; 4] {
        let [l, t, r, b] = self.edges;
        [
            Point { x: l, y: t },
            Point { x: r, y: t },
            Point { x: r, y: b },
            Point { x: l, y: b },
        ]
    }
}
impl TryFrom<[f64; 4]> for Rect {
    type Error = Error;
    fn try_from(v: [f64; 4]) -> Result<Self> {
        Self::new(v[0], v[1], v[2], v[3])
    }
}
impl From<Rect> for [f64; 4] {
    fn from(v: Rect) -> Self {
        v.edges
    }
}

/// A finite, nondegenerate polygon. The adapter is responsible for contour semantics.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(try_from = "Vec<Point>", into = "Vec<Point>")]
pub struct Polygon(Vec<Point>);
impl Polygon {
    /// Validate vertex count and nonzero finite signed area.
    pub fn new(points: Vec<Point>) -> Result<Self> {
        if points.len() < 3 {
            return Err(Error::input("polygon needs at least three points"));
        }
        let origin = points[0];
        let area: f64 = points
            .iter()
            .zip(points.iter().cycle().skip(1))
            .take(points.len())
            .map(|(a, b)| (a.x - origin.x) * (b.y - origin.y) - (b.x - origin.x) * (a.y - origin.y))
            .sum();
        if !area.is_finite() || area == 0.0 {
            return Err(Error::input("degenerate polygon"));
        }
        Ok(Self(points))
    }
    /// Ordered vertices.
    pub fn points(&self) -> &[Point] {
        &self.0
    }
}
impl TryFrom<Vec<Point>> for Polygon {
    type Error = Error;
    fn try_from(v: Vec<Point>) -> Result<Self> {
        Self::new(v)
    }
}
impl From<Polygon> for Vec<Point> {
    fn from(v: Polygon) -> Self {
        v.0
    }
}

/// Invertible affine map: `x'=a*x+c*y+tx`, `y'=b*x+d*y+ty`.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(try_from = "[f64; 6]", into = "[f64; 6]")]
pub struct Affine([f64; 6]);
impl Affine {
    /// Identity map.
    pub const IDENTITY: Self = Self([1., 0., 0., 1., 0., 0.]);
    /// Validate coefficients and a finite inverse, without an arbitrary epsilon cutoff.
    pub fn new(values: [f64; 6]) -> Result<Self> {
        finite(&values)?;
        let value = Self(values);
        value.inverse_values()?;
        Ok(value)
    }
    fn inverse_values(self) -> Result<[f64; 6]> {
        let [a, b, c, d, tx, ty] = self.0;
        let determinant = a * d - b * c;
        if determinant == 0. || !determinant.is_finite() {
            return Err(Error::input("singular or overflowing affine transform"));
        }
        let values = [
            d / determinant,
            -b / determinant,
            -c / determinant,
            a / determinant,
            (c * ty - d * tx) / determinant,
            (b * tx - a * ty) / determinant,
        ];
        finite(&values)?;
        Ok(values)
    }
    /// Inverse mapping.
    pub fn inverse(self) -> Result<Self> {
        Self::new(self.inverse_values()?)
    }
    /// Transform a point, rejecting arithmetic overflow.
    pub fn map(self, point: Point) -> Result<Point> {
        let [a, b, c, d, tx, ty] = self.0;
        Point::new(
            a * point.x + c * point.y + tx,
            b * point.x + d * point.y + ty,
        )
    }
    /// Coefficients in a/b/c/d/tx/ty order.
    pub fn coefficients(self) -> [f64; 6] {
        self.0
    }
    /// Map every corner and return their axis-aligned envelope.
    pub fn map_rect(self, rect: Rect) -> Result<Rect> {
        let mut edges = [
            f64::INFINITY,
            f64::INFINITY,
            f64::NEG_INFINITY,
            f64::NEG_INFINITY,
        ];
        for corner in rect.corners() {
            let p = self.map(corner)?;
            edges = [
                edges[0].min(p.x),
                edges[1].min(p.y),
                edges[2].max(p.x),
                edges[3].max(p.y),
            ];
        }
        Rect::try_from(edges)
    }
    /// Convert page bounds to a covering raster crop using the inverse map.
    pub fn crop_pixels(self, bounds: Rect, width: u32, height: u32) -> Result<PixelCrop> {
        let [l, t, r, b] = self.inverse()?.map_rect(bounds)?.edges;
        let left = l.floor().clamp(0., f64::from(width)) as u32;
        let top = t.floor().clamp(0., f64::from(height)) as u32;
        let right = r.ceil().clamp(0., f64::from(width)) as u32;
        let bottom = b.ceil().clamp(0., f64::from(height)) as u32;
        if left >= right || top >= bottom {
            return Err(Error::input("crop does not intersect the raster"));
        }
        Ok(PixelCrop {
            left,
            top,
            right,
            bottom,
        })
    }
}
impl TryFrom<[f64; 6]> for Affine {
    type Error = Error;
    fn try_from(v: [f64; 6]) -> Result<Self> {
        Self::new(v)
    }
}
impl From<Affine> for [f64; 6] {
    fn from(v: Affine) -> Self {
        v.0
    }
}

/// Integer pixel-edge crop; right and bottom are exclusive.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PixelCrop {
    /// Inclusive left edge.
    pub left: u32,
    /// Inclusive top edge.
    pub top: u32,
    /// Exclusive right edge.
    pub right: u32,
    /// Exclusive bottom edge.
    pub bottom: u32,
}
