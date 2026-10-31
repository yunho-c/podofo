//! Owned, portable failure categories. No backend or foreign exception escapes here.
use serde::{Deserialize, Serialize};
use std::fmt;

/// An operation with an owned Podoco error.
pub type Result<T> = std::result::Result<T, Error>;

/// Stable machine-readable failure categories; messages are diagnostic text.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[non_exhaustive]
pub enum ErrorCode {
    /// Invalid identity, geometry, image, or options.
    InvalidInput,
    /// An explicit memory or count budget was exceeded.
    LimitExceeded,
    /// The configured bundle cannot perform a requested operation.
    UnsupportedCapability,
    /// A manifest is malformed or describes an unsupported contract.
    InvalidManifest,
    /// Missing, changed, or unexpected model payload.
    InvalidAsset,
    /// Filesystem access failed.
    Io,
    /// A serialized result is malformed or internally inconsistent.
    InvalidResult,
    /// A required schema version or variant is unsupported.
    UnsupportedSchema,
    /// Rendering failed for a page.
    PageSource,
    /// The immutable source revision changed.
    SourceChanged,
    /// Layout processing failed.
    Layout,
    /// Formula recognition failed.
    Recognition,
    /// LaTeX/MathML conversion or mathematical speech failed.
    Conversion,
    /// The inference backend failed.
    Backend,
    /// Delivery to the application failed.
    Delivery,
    /// Cancellation was observed.
    Cancelled,
    /// A worker stopped unexpectedly.
    WorkerFailed,
}

/// An owned failure, also suitable for persistent results.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Error {
    /// Stable failure category.
    pub code: ErrorCode,
    /// Human-readable context, not a machine parsing interface.
    pub message: String,
}
impl Error {
    /// Construct an owned error.
    pub fn new(code: ErrorCode, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }
    pub(crate) fn input(message: impl Into<String>) -> Self {
        Self::new(ErrorCode::InvalidInput, message)
    }
    pub(crate) fn result(message: impl Into<String>) -> Self {
        Self::new(ErrorCode::InvalidResult, message)
    }
    pub(crate) fn io(path: &std::path::Path, error: std::io::Error) -> Self {
        Self::new(ErrorCode::Io, format!("{}: {error}", path.display()))
    }
}
impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{:?}: {}", self.code, self.message)
    }
}
impl std::error::Error for Error {}
