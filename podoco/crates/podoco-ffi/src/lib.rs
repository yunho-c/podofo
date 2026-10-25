//! C ABI adapter for Podoco.
//!
//! Version queries allocate nothing and cannot panic. Regenerate the checked-in
//! C header and Dart bindings after changing the exported API.

use std::ffi::c_char;

const VERSION_C: &str = concat!(env!("CARGO_PKG_VERSION"), "\0");

/// Returns the C ABI compatibility version.
///
/// Bindings must check compatibility before calling other entry points.
/// Version 1 currently contains library identity queries only.
// SAFETY: This uniquely named exported symbol uses the C calling convention.
#[unsafe(no_mangle)]
pub extern "C" fn podoco_abi_version() -> u32 {
    1
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
