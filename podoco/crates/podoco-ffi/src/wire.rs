//! Pointer validation and panic containment are confined to the FFI crate.
use crate::{
    handles::{self, Entry},
    types::*,
};
use podoco::{Error, ErrorCode, Result};
use serde::{Serialize, de::DeserializeOwned};
use std::{
    io::Write,
    panic::{AssertUnwindSafe, catch_unwind},
};

pub(crate) fn invalid(message: impl Into<String>) -> Error {
    Error::new(ErrorCode::InvalidInput, message)
}
pub(crate) unsafe fn input<'a>(value: PodocoBytes, max: u64) -> Result<&'a [u8]> {
    if value.len > max || value.len > isize::MAX as u64 || (value.data.is_null() && value.len != 0)
    {
        return Err(invalid("null or oversized byte input"));
    }
    if value.len == 0 {
        return Ok(&[]);
    }
    // SAFETY: Exported caller guarantees readable initialized storage; numeric
    // checks above constrain the one-allocation slice length.
    Ok(unsafe { std::slice::from_raw_parts(value.data, value.len as usize) })
}
pub(crate) unsafe fn json<T: DeserializeOwned>(value: PodocoBytes) -> Result<T> {
    // SAFETY: Inherited readable-input contract from each exported entry point.
    let bytes = unsafe { input(value, PODOCO_MAX_METADATA_BYTES) }?;
    serde_json::from_slice(bytes).map_err(|e| invalid(format!("metadata: {e}")))
}
pub(crate) fn schema(version: u32) -> Result<()> {
    if version != PODOCO_SCHEMA_VERSION {
        Err(Error::new(
            ErrorCode::UnsupportedSchema,
            "unsupported metadata schema",
        ))
    } else {
        Ok(())
    }
}
pub(crate) unsafe fn clear(pointer: *mut u64) -> Result<()> {
    if pointer.is_null() {
        return Err(invalid("required output handle is null"));
    }
    // SAFETY: Exported caller supplies aligned writable disjoint output storage.
    unsafe {
        pointer.write(0);
    }
    Ok(())
}
pub(crate) unsafe fn guard(
    error: *mut u64,
    operation: impl FnOnce() -> Result<PodocoStatus>,
) -> PodocoStatus {
    if !error.is_null() {
        // SAFETY: Optional error output is writable and disjoint when non-null.
        unsafe {
            error.write(0);
        }
    }
    match catch_unwind(AssertUnwindSafe(operation)) {
        Ok(Ok(status)) => status,
        result => {
            let failure = match result {
                Ok(Err(e)) => e,
                _ => Error::new(ErrorCode::WorkerFailed, "panic contained at C ABI boundary"),
            };
            if !error.is_null()
                && let Ok(Ok(id)) = catch_unwind(AssertUnwindSafe(|| {
                    buffer(&failure, PODOCO_MAX_METADATA_BYTES)
                }))
            {
                // SAFETY: Same writable error output; error owns a JSON buffer.
                unsafe {
                    error.write(id);
                }
            }
            PODOCO_ERROR
        }
    }
}
/// Bounded serializer: no temporary unbounded Vec produced before the check.
pub(crate) fn encode(value: &impl Serialize, max: u64) -> Result<Box<[u8]>> {
    struct Writer {
        bytes: Vec<u8>,
        max: usize,
        exceeded: bool,
    }
    impl Write for Writer {
        fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
            if bytes.len() > self.max.saturating_sub(self.bytes.len()) {
                self.exceeded = true;
                return Err(std::io::Error::other("metadata byte limit"));
            }
            let needed = self.bytes.len() + bytes.len();
            if needed > self.bytes.capacity() {
                let capacity = self
                    .bytes
                    .capacity()
                    .saturating_mul(2)
                    .max(needed)
                    .min(self.max);
                self.bytes
                    .try_reserve_exact(capacity - self.bytes.len())
                    .map_err(std::io::Error::other)?;
            }
            self.bytes.extend_from_slice(bytes);
            Ok(bytes.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }
    let mut writer = Writer {
        bytes: Vec::new(),
        max: max.min(isize::MAX as u64) as usize,
        exceeded: false,
    };
    serde_json::to_writer(&mut writer, value).map_err(|e| {
        Error::new(
            if writer.exceeded {
                ErrorCode::LimitExceeded
            } else {
                ErrorCode::InvalidResult
            },
            e.to_string(),
        )
    })?;
    Ok(writer.bytes.into_boxed_slice())
}
pub(crate) fn buffer(value: &impl Serialize, max: u64) -> Result<u64> {
    handles::insert(Entry::Buffer(encode(value, max)?))
}
