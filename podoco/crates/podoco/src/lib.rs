//! Podoco's public Rust API for document analysis.
//!
//! Validated page/image contracts, portable results, and offline model bundles.
//! Inference and document job execution are not implemented yet.
//!
//! Rust callers use this crate directly. Foreign-language bindings delegate
//! through `podoco-ffi`; the Rust implementation does not depend on the ABI,
//! Flutter, or PoDoFo application state.
//!
//! ```
//! assert!(!podoco::VERSION.is_empty());
//! ```

#![deny(unsafe_code)]

pub mod bundle;
pub mod domain;
pub mod error;
pub mod geometry;
pub mod image;
pub mod options;
pub mod results;

pub use bundle::ModelBundle;
pub use domain::{AnalysisId, DocumentRef, PageDescriptor, PageKey, ProfileId, RegionId};
pub use error::{Error, ErrorCode, Result};
pub use geometry::{Affine, PageSpace, Point, Polygon, Rect};
pub use image::{AlphaMode, ImageDescriptor, PageImage, PageInput, PixelFormat};
pub use options::{AnalysisOptions, AnalyzerOptions, Capabilities, FormulaScope, ResourceLimits};
pub use results::{AnalysisUpdate, FormulaOutcome, LayoutRegion, PageAnalysis};

#[cfg(all(feature = "coreml", not(any(target_os = "macos", target_os = "ios"))))]
compile_error!("Podoco's coreml feature requires macOS or iOS.");

/// The version of the Podoco Rust library.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");
