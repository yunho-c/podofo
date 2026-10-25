//! Podoco's public Rust API for document analysis.
//!
//! This initial scaffold exposes library identity only. Model loading,
//! inference, and document analysis are not implemented yet.
//!
//! Rust callers use this crate directly. Foreign-language bindings delegate
//! through `podoco-ffi`; the Rust implementation does not depend on the ABI,
//! Flutter, or PoDoFo application state.
//!
//! ```
//! assert!(!podoco::VERSION.is_empty());
//! ```

#![forbid(unsafe_code)]

/// The version of the Podoco Rust library.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");
