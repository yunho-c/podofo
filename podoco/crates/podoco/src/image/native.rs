//! Sole image-pointer import boundary. No native model objects live here.
use super::{ImageDescriptor, PageImage, Storage, validate_storage};
use crate::Error;
use std::{ptr::NonNull, sync::Arc};

/// Ownership of stable initialized native pixels with all writes excluded.
/// Construction is unsafe; importing the lease validates its image descriptor.
pub struct NativeLease {
    pointer: NonNull<u8>,
    initialized: usize,
    retained: usize,
    release: Option<Box<dyn FnOnce() + Send>>,
}
// SAFETY: construction requires initialized storage with exclusive write
// exclusion for the entire lease lifetime. The release callback is Send.
unsafe impl Send for NativeLease {}
// SAFETY: only shared immutable bytes are accessible, and Drop runs exclusively
// after the final Arc reader. The callback is never accessed through &self.
unsafe impl Sync for NativeLease {}
impl NativeLease {
    /// Adopt native storage and its exactly-once release action.
    ///
    /// # Safety
    /// `pointer` covers `initialized` initialized bytes (including padding) in
    /// one live allocation; length is at most isize::MAX. No writes or freeing
    /// may occur until release. `retained` accounts for the entire allocation.
    /// `release` must not panic and must be safe on any final-owner thread.
    pub unsafe fn new(
        pointer: NonNull<u8>,
        initialized: usize,
        retained: usize,
        release: Box<dyn FnOnce() + Send>,
    ) -> Self {
        Self {
            pointer,
            initialized,
            retained,
            release: Some(release),
        }
    }
    pub(super) fn bytes(&self) -> &[u8] {
        // SAFETY: guaranteed by construction; the borrow keeps the owner alive.
        unsafe { std::slice::from_raw_parts(self.pointer.as_ptr(), self.initialized) }
    }
    pub(super) fn retained_bytes(&self) -> usize {
        self.retained
    }
}
impl Drop for NativeLease {
    fn drop(&mut self) {
        if let Some(release) = self.release.take() {
            release();
        }
    }
}
/// A rejected import retains its owner, so callers can retry or drop it.
pub struct RejectedLease {
    /// Validation failure.
    pub error: Error,
    /// Original lease, not yet released.
    pub lease: NativeLease,
}
/// Validate storage, returning the original lease on rejection. No input copy.
pub fn import(
    descriptor: ImageDescriptor,
    lease: NativeLease,
    budget: u64,
) -> std::result::Result<PageImage, RejectedLease> {
    if let Err(error) = validate_storage(descriptor, lease.initialized, lease.retained, budget) {
        return Err(RejectedLease { error, lease });
    }
    Ok(PageImage {
        descriptor,
        storage: Arc::new(Storage::Native(lease)),
    })
}

#[cfg(test)]
pub(super) fn owned_for_test(
    descriptor: ImageDescriptor,
    mut bytes: Vec<u8>,
    released: Box<dyn FnOnce() + Send>,
) -> PageImage {
    let pointer = NonNull::new(bytes.as_mut_ptr()).expect("test allocation");
    // SAFETY: This test helper transfers the initialized Vec into the sole
    // release closure and exposes no writable aliases during the lease.
    let lease = unsafe {
        NativeLease::new(
            pointer,
            bytes.len(),
            bytes.capacity(),
            Box::new(move || {
                drop(bytes);
                released();
            }),
        )
    };
    import(descriptor, lease, u64::MAX)
        .ok()
        .expect("valid test descriptor")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{AlphaMode, PixelFormat};
    use std::sync::atomic::{AtomicUsize, Ordering};
    fn lease(counter: Arc<AtomicUsize>) -> NativeLease {
        let mut bytes = vec![7u8; 16];
        let pointer = NonNull::new(bytes.as_mut_ptr()).unwrap();
        // SAFETY: the callback owns stable initialized storage, exposes no
        // writable aliases, and frees it only after all immutable reads finish.
        unsafe {
            NativeLease::new(
                pointer,
                16,
                16,
                Box::new(move || {
                    drop(bytes);
                    counter.fetch_add(1, Ordering::SeqCst);
                }),
            )
        }
    }
    fn descriptor() -> ImageDescriptor {
        ImageDescriptor::new(2, 2, 8, PixelFormat::Bgra8, AlphaMode::Opaque).unwrap()
    }
    #[test]
    fn rejection_returns_owner_then_last_reader_releases_on_another_thread() {
        let counter = Arc::new(AtomicUsize::new(0));
        let rejected = import(descriptor(), lease(counter.clone()), 15)
            .err()
            .unwrap();
        assert_eq!(rejected.error.code, crate::ErrorCode::LimitExceeded);
        assert_eq!(counter.load(Ordering::SeqCst), 0);
        let image = import(descriptor(), rejected.lease, 16).ok().unwrap();
        let reader = image.clone();
        drop(image);
        assert_eq!(counter.load(Ordering::SeqCst), 0);
        std::thread::spawn(move || {
            assert_eq!(reader.row(1).unwrap(), &[7; 8]);
        })
        .join()
        .unwrap();
        assert_eq!(counter.load(Ordering::SeqCst), 1);
    }
    #[test]
    fn unwind_releases_once() {
        let counter = Arc::new(AtomicUsize::new(0));
        let image = import(descriptor(), lease(counter.clone()), 16)
            .ok()
            .unwrap();
        let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(move || {
            let _reader = image;
            panic!("simulated worker failure");
        }));
        assert!(outcome.is_err());
        assert_eq!(counter.load(Ordering::SeqCst), 1);
    }
}
