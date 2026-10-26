//! Immutable copied images and an isolated internal native ownership boundary.
use crate::{Affine, Error, ErrorCode, PageDescriptor, ProfileId, Rect, Result};
use serde::{Deserialize, Serialize};
use std::{fmt, sync::Arc};

// The future FFI adapter will use this boundary. Until M4 its callers are the
// ownership tests; allowing dead code here does not expose an unqualified API.
#[allow(unsafe_code)]
#[cfg_attr(not(test), allow(dead_code))]
mod native;

/// Byte order of each four-byte pixel.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PixelFormat {
    /// Blue, green, red, alpha.
    Bgra8,
    /// Red, green, blue, alpha.
    Rgba8,
}
/// Interpretation of alpha during future preprocessing.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AlphaMode {
    /// Alpha is ignored; colors are opaque.
    Opaque,
    /// Colors are independent of alpha.
    Straight,
    /// Colors have already been multiplied by alpha.
    Premultiplied,
}

/// A checked top-to-bottom four-byte raster layout, without storage ownership.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(try_from = "DescriptorWire", into = "DescriptorWire")]
pub struct ImageDescriptor(DescriptorWire);
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
struct DescriptorWire {
    width: u32,
    height: u32,
    row_stride: u64,
    format: PixelFormat,
    alpha: AlphaMode,
}
impl ImageDescriptor {
    /// Validate dimensions, row size, and host-addressable storage span.
    pub fn new(
        width: u32,
        height: u32,
        row_stride: u64,
        format: PixelFormat,
        alpha: AlphaMode,
    ) -> Result<Self> {
        Self::try_from(DescriptorWire {
            width,
            height,
            row_stride,
            format,
            alpha,
        })
    }
    /// Raster width in pixels.
    pub fn width(self) -> u32 {
        self.0.width
    }
    /// Raster height in pixels.
    pub fn height(self) -> u32 {
        self.0.height
    }
    /// Positive byte stride between rows.
    pub fn row_stride(self) -> usize {
        self.0.row_stride as usize
    }
    /// Pixel channel order.
    pub fn format(self) -> PixelFormat {
        self.0.format
    }
    /// Alpha interpretation, preserved without conversion during copying.
    pub fn alpha(self) -> AlphaMode {
        self.0.alpha
    }
    /// Required initialized span, excluding unnecessary trailing row padding.
    pub fn required_bytes(self) -> usize {
        ((u64::from(self.0.height) - 1) * self.0.row_stride + u64::from(self.0.width) * 4) as usize
    }
}
impl TryFrom<DescriptorWire> for ImageDescriptor {
    type Error = Error;
    fn try_from(v: DescriptorWire) -> Result<Self> {
        let row = u64::from(v.width) * 4;
        let span = u64::from(v.height)
            .checked_sub(1)
            .and_then(|h| h.checked_mul(v.row_stride))
            .and_then(|x| x.checked_add(row));
        if v.width == 0
            || v.height == 0
            || v.row_stride < row
            || usize::try_from(v.row_stride).is_err()
            || span.is_none_or(|n| n > isize::MAX as u64)
        {
            return Err(Error::input(
                "invalid image dimensions, stride, or storage span",
            ));
        }
        Ok(Self(v))
    }
}
impl From<ImageDescriptor> for DescriptorWire {
    fn from(v: ImageDescriptor) -> Self {
        v.0
    }
}

enum Storage {
    Copied(Box<[u8]>),
    Native(native::NativeLease),
}
impl Storage {
    fn bytes(&self) -> &[u8] {
        match self {
            Self::Copied(b) => b,
            Self::Native(b) => b.bytes(),
        }
    }
    fn retained_bytes(&self) -> usize {
        match self {
            Self::Copied(b) => b.len(),
            Self::Native(b) => b.retained_bytes(),
        }
    }
}
/// Immutable SDK-owned image. Clones retain the same allocation, never writable views.
#[derive(Clone)]
pub struct PageImage {
    descriptor: ImageDescriptor,
    storage: Arc<Storage>,
}
impl fmt::Debug for PageImage {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PageImage")
            .field("descriptor", &self.descriptor)
            .field("retained_bytes", &self.retained_bytes())
            .finish_non_exhaustive()
    }
}
impl PageImage {
    /// Copy the entire supplied initialized byte view before returning.
    ///
    /// Padding and trailing bytes count against `byte_budget`. The caller can
    /// immediately overwrite or release its source after a successful return.
    pub fn copy(descriptor: ImageDescriptor, bytes: &[u8], byte_budget: u64) -> Result<Self> {
        validate_storage(descriptor, bytes.len(), bytes.len(), byte_budget)?;
        Ok(Self {
            descriptor,
            storage: Arc::new(Storage::Copied(bytes.into())),
        })
    }
    /// Validated image descriptor.
    pub fn descriptor(&self) -> ImageDescriptor {
        self.descriptor
    }
    /// Full allocation retained by this image, including padding.
    pub fn retained_bytes(&self) -> usize {
        self.storage.retained_bytes()
    }
    /// One row's pixels, excluding padding; no channel conversion is performed.
    pub fn row(&self, index: u32) -> Option<&[u8]> {
        if index >= self.descriptor.height() {
            return None;
        }
        let start = index as usize * self.descriptor.row_stride();
        Some(&self.storage.bytes()[start..start + self.descriptor.width() as usize * 4])
    }
}
fn validate_storage(
    descriptor: ImageDescriptor,
    initialized: usize,
    retained: usize,
    budget: u64,
) -> Result<()> {
    if initialized < descriptor.required_bytes()
        || initialized > retained
        || initialized > isize::MAX as usize
    {
        return Err(Error::input(
            "storage does not cover the image's initialized span",
        ));
    }
    if retained as u64 > budget {
        return Err(Error::new(
            ErrorCode::LimitExceeded,
            "retained image allocation exceeds input budget",
        ));
    }
    Ok(())
}

/// Complete page input. Its pixels are never serialized with semantic results.
#[derive(Clone, Debug)]
pub struct PageInput {
    descriptor: PageDescriptor,
    image: PageImage,
    pixel_to_page: Affine,
    render_profile: ProfileId,
}
/// Failed page construction returning the unaccepted image to its owner.
#[derive(Debug)]
pub struct RejectedPageInput {
    /// Validation failure.
    pub error: Error,
    /// The caller retains ownership and may retry or release this image.
    pub image: PageImage,
}
impl PageInput {
    /// Validate the pixel mapping before handing ownership to a future job.
    pub fn new(
        descriptor: PageDescriptor,
        image: PageImage,
        pixel_to_page: Affine,
        render_profile: ProfileId,
    ) -> std::result::Result<Self, RejectedPageInput> {
        let raster = Rect::new(
            0.,
            0.,
            f64::from(image.descriptor.width()),
            f64::from(image.descriptor.height()),
        );
        if let Err(error) = raster.and_then(|r| pixel_to_page.map_rect(r)) {
            return Err(RejectedPageInput { error, image });
        }
        Ok(Self {
            descriptor,
            image,
            pixel_to_page,
            render_profile,
        })
    }
    /// Source identity and logical dimensions.
    pub fn descriptor(&self) -> &PageDescriptor {
        &self.descriptor
    }
    /// Immutable source-resolution pixels.
    pub fn image(&self) -> &PageImage {
        &self.image
    }
    /// Pixel-edge to canonical page mapping.
    pub fn pixel_to_page(&self) -> Affine {
        self.pixel_to_page
    }
    /// Render policy recorded in provenance.
    pub fn render_profile(&self) -> &ProfileId {
        &self.render_profile
    }
}
