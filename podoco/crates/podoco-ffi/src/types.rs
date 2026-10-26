//! Fixed-layout C values. Opaque handles are IDs, never dereferenced addresses.

/// Opaque library handle. Zero is null; IDs are never reused and fit signed 64 bits.
pub type PodocoHandle = u64;
/// Operation status; on failure the optional error handle owns a JSON diagnostic.
pub type PodocoStatus = i32;
/// Operation succeeded.
pub const PODOCO_OK: PodocoStatus = 0;
/// No source request/result/outcome is ready yet.
pub const PODOCO_PENDING: PodocoStatus = 1;
/// Operation failed. Read and release the optional error buffer.
pub const PODOCO_ERROR: PodocoStatus = -1;
/// Image copying/import and owned JSON buffers are available.
pub const PODOCO_FEATURE_IMAGES: u32 = 1;
/// Core ML was compiled into this artifact; model capability is checked at open.
pub const PODOCO_FEATURE_COREML: u32 = 2;
/// Formula bundle verification and analyzer formula configuration are available.
/// Probe this additive ABI-2 extension before resolving formula entry points.
pub const PODOCO_FEATURE_FORMULA: u32 = 8;
/// Current semantic result and FFI metadata schema.
pub const PODOCO_SCHEMA_VERSION: u32 = 0;
/// Maximum input metadata JSON bytes (4 MiB), independent of image size.
pub const PODOCO_MAX_METADATA_BYTES: u64 = 4 * 1024 * 1024;

/// Borrowed bytes for one call; output bytes live until their owning buffer is
/// released. Null is valid only for zero length. Inputs are copied before return.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct PodocoBytes {
    /// First readable initialized byte.
    pub data: *const u8,
    /// Byte length, excluding any terminator.
    pub len: u64,
}
impl Default for PodocoBytes {
    fn default() -> Self {
        Self {
            data: std::ptr::null(),
            len: 0,
        }
    }
}

/// Raw BGRA/RGBA image description. Initialize every field. This ABI fixes the
/// layout; struct_size must equal sizeof(PodocoImageDescriptor).
#[repr(C)]
#[derive(Clone, Copy)]
pub struct PodocoImageDescriptor {
    /// Exact struct size, in bytes.
    pub struct_size: u32,
    /// Width in pixels.
    pub width: u32,
    /// Height in pixels.
    pub height: u32,
    /// 0: BGRA8; 1: RGBA8.
    pub pixel_format: u32,
    /// 0: opaque; 1: straight; 2: premultiplied.
    pub alpha_mode: u32,
    /// Must be zero.
    pub reserved: u32,
    /// Bytes between rows, including padding.
    pub row_bytes: u64,
}

/// Native lease release notification. Called exactly once, on any final-reader
/// thread, with only the supplied scalar token. Must not panic/unwind or block.
/// Keep the callback callable until that notification has been consumed.
pub type PodocoRelease = Option<unsafe extern "C" fn(token: u64)>;

/// Native source/result wakeup: scalar token only, no temporary pointers. The
/// callback must enqueue work and return promptly; it cannot wait/close a job.
/// Null selects explicit polling. Keep it alive until native close/drain and all
/// pending binding notifications have been consumed.
pub type PodocoWake = Option<unsafe extern "C" fn(token: u64)>;
/// Rust-owned document scheduling and source/result transport are available.
pub const PODOCO_FEATURE_JOBS: u32 = 4;
