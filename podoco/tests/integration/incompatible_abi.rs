//! Identity-only ABI 1 native library for testing Dart's ABI guard.

use std::ffi::c_char;

// SAFETY: Test-only library with the expected C ABI symbol and signature.
#[unsafe(no_mangle)]
pub extern "C" fn podoco_abi_version() -> u32 {
    1
}

// SAFETY: Test-only library returning a static NUL-terminated string.
#[unsafe(no_mangle)]
pub extern "C" fn podoco_version() -> *const c_char {
    c"incompatible-library-must-not-be-used".as_ptr()
}
