//! Older ABI 2 with no formula extension: new Dart must probe before lookup.

#[unsafe(no_mangle)]
pub extern "C" fn podoco_abi_version() -> u32 {
    2
}

#[unsafe(no_mangle)]
pub extern "C" fn podoco_features() -> u32 {
    0
}
