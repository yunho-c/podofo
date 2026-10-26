//! C ABI adapter for Podoco.
//!
//! Version queries allocate nothing and cannot panic. Regenerate the checked-in
//! C header and Dart bindings after changing the exported API.

mod api;
mod handles;
mod jobs;
mod transport;
mod types;
pub use jobs::*;
mod wire;
pub use api::*;
pub use types::*;

use std::ffi::c_char;

const VERSION_C: &str = concat!(env!("CARGO_PKG_VERSION"), "\0");

/// Returns the C ABI compatibility version.
///
/// Bindings must check compatibility before calling other entry points.
/// Version 2 adds owned handles, images, and the analysis transport. Identity-only
/// version-1 libraries must be rejected before resolving version-2 symbols.
// SAFETY: This uniquely named exported symbol uses the C calling convention.
#[unsafe(no_mangle)]
pub extern "C" fn podoco_abi_version() -> u32 {
    2
}

/// Returns the library version as a borrowed, NUL-terminated UTF-8 string.
///
/// The pointer is non-null and remains valid while the library is loaded.
/// Do not modify or free it. This function is thread-safe.
// SAFETY: This uniquely named exported symbol uses the C calling convention.
#[unsafe(no_mangle)]
pub extern "C" fn podoco_version() -> *const c_char {
    VERSION_C.as_ptr().cast()
}

#[cfg(test)]
mod tests {
    use std::ffi::CStr;

    #[test]
    fn borrowed_version_matches_rust_api() {
        let pointer = super::podoco_version();
        assert!(!pointer.is_null());
        assert_eq!(pointer, super::podoco_version());
        // SAFETY: podoco_version returns a static NUL-terminated string.
        let version = unsafe { CStr::from_ptr(pointer) };
        assert_eq!(version.to_str().unwrap(), podoco::VERSION);
    }
}

#[cfg(test)]
#[path = "tests.rs"]
mod analysis_tests;
