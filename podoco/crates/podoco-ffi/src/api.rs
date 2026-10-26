use crate::{
    handles::{self, Entry, Kind, OwnedAnalyzer},
    types::*,
    wire::*,
};
use podoco::{
    AlphaMode, Analyzer, AnalyzerOptions, ImageDescriptor, ModelBundle, PageImage, PixelFormat,
};
use serde::Deserialize;
use std::{
    panic::{AssertUnwindSafe, catch_unwind},
    ptr::NonNull,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
};

/// Built features; model-specific capabilities are queried on the analyzer.
#[unsafe(no_mangle)]
pub extern "C" fn podoco_features() -> u32 {
    PODOCO_FEATURE_IMAGES
        | PODOCO_FEATURE_JOBS
        | PODOCO_FEATURE_FORMULA
        | if cfg!(feature = "coreml") {
            PODOCO_FEATURE_COREML
        } else {
            0
        }
}
/// Live registry entries, for leak diagnostics. This is not process memory.
#[unsafe(no_mangle)]
pub extern "C" fn podoco_live_handles() -> u64 {
    handles::count()
}
/// Release any owned handle; zero is a no-op, stale nonzero handles fail.
/// Last-owner release can block while an analyzer/job drains. Do not call from
/// its source/sink wake callback or a UI thread. No registry lock is held while
/// dropping the resource or invoking an image release notification.
#[unsafe(no_mangle)]
pub extern "C" fn podoco_release(handle: PodocoHandle) -> PodocoStatus {
    match catch_unwind(AssertUnwindSafe(|| handles::release(handle))) {
        Ok(Ok(())) => PODOCO_OK,
        _ => PODOCO_ERROR,
    }
}
/// Borrow bytes from a result/error buffer until its handle is released. Copy
/// before invoking async caller code. Never release concurrently with this view.
/// # Safety
/// Outputs are aligned, writable, and disjoint; error may be null. Handle IDs
/// themselves may be arbitrary. All pointer APIs use this output contract.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn podoco_buffer_view(
    handle: PodocoHandle,
    output: *mut PodocoBytes,
    error: *mut PodocoHandle,
) -> PodocoStatus {
    // SAFETY: The exported output contract applies to guard and writes below.
    unsafe {
        guard(error, || {
            if output.is_null() {
                return Err(invalid("buffer output is null"));
            }
            output.write(PodocoBytes::default());
            let entry = handles::get(handle, Kind::Buffer)?;
            let Entry::Buffer(bytes) = entry.as_ref() else {
                unreachable!()
            };
            output.write(PodocoBytes {
                data: bytes.as_ptr(),
                len: bytes.len() as u64,
            });
            Ok(PODOCO_OK)
        })
    }
}
unsafe fn descriptor(pointer: *const PodocoImageDescriptor) -> podoco::Result<ImageDescriptor> {
    if pointer.is_null() {
        return Err(invalid("image descriptor is null"));
    }
    // SAFETY: Caller provides at least an aligned readable struct_size field.
    if unsafe { pointer.cast::<u32>().read() } != size_of::<PodocoImageDescriptor>() as u32 {
        return Err(invalid("incompatible image descriptor size"));
    }
    // SAFETY: On matching size, caller guarantees the complete readable struct.
    let d = unsafe { pointer.read() };
    if d.reserved != 0 {
        return Err(invalid("reserved image field must be zero"));
    }
    let format = match d.pixel_format {
        0 => PixelFormat::Bgra8,
        1 => PixelFormat::Rgba8,
        _ => return Err(invalid("unknown pixel format")),
    };
    let alpha = match d.alpha_mode {
        0 => AlphaMode::Opaque,
        1 => AlphaMode::Straight,
        2 => AlphaMode::Premultiplied,
        _ => return Err(invalid("unknown alpha mode")),
    };
    ImageDescriptor::new(d.width, d.height, d.row_bytes, format, alpha)
}
/// Copy the complete initialized view, including supplied padding/trailing
/// bytes. Caller storage can be modified/freed immediately after return.
/// # Safety
/// Descriptor and bytes cover their stated initialized readable storage for this
/// call. Outputs follow podoco_buffer_view's disjoint writable contract.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn podoco_image_copy(
    description: *const PodocoImageDescriptor,
    bytes: PodocoBytes,
    byte_budget: u64,
    output: *mut PodocoHandle,
    error: *mut PodocoHandle,
) -> PodocoStatus {
    // SAFETY: Exported caller guarantees all input/output pointer preconditions.
    unsafe {
        guard(error, || {
            clear(output)?;
            let d = descriptor(description)?;
            let image = PageImage::copy(d, input(bytes, byte_budget)?, byte_budget)?;
            output.write(handles::insert(Entry::Image(image))?);
            Ok(PODOCO_OK)
        })
    }
}
/// Import a native image without copying its pixels. On success all writes and
/// freeing are forbidden until release(token); on rejection ownership stays
/// with the caller and the release callback is NOT invoked. Retained bytes
/// account for the whole allocation, not just the initialized view.
/// # Safety
/// Descriptor/outputs satisfy podoco_image_copy's contract. The pixel pointer
/// covers one allocation with bytes.len initialized bytes (including padding),
/// and remains valid and immutable until release. The callback is non-null,
/// thread-safe, nonblocking, cannot unwind, and stays callable through release.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn podoco_image_import(
    description: *const PodocoImageDescriptor,
    bytes: PodocoBytes,
    retained_bytes: u64,
    byte_budget: u64,
    release: PodocoRelease,
    token: u64,
    output: *mut PodocoHandle,
    error: *mut PodocoHandle,
) -> PodocoStatus {
    // SAFETY: The exported caller guarantees native storage/callback lifetime.
    unsafe {
        guard(error, || {
            clear(output)?;
            let d = descriptor(description)?;
            let callback = release.ok_or_else(|| invalid("native release callback is required"))?;
            if bytes.len > isize::MAX as u64 || retained_bytes > usize::MAX as u64 {
                return Err(invalid("native storage length exceeds addressable range"));
            }
            let pointer = NonNull::new(bytes.data.cast_mut())
                .ok_or_else(|| invalid("native pixels are null"))?;
            // Arm only after successful publication; every earlier exit keeps the
            // caller's ownership and never invokes its release function.
            let accepted = Arc::new(AtomicBool::new(false));
            let armed = accepted.clone();
            let lease = podoco::image::native::NativeLease::new(
                pointer,
                bytes.len as usize,
                retained_bytes as usize,
                Box::new(move || {
                    if armed.load(Ordering::Acquire) {
                        callback(token);
                    }
                }),
            );
            let image =
                podoco::image::native::import(d, lease, byte_budget).map_err(|e| e.error)?;
            let handle = handles::insert(Entry::Image(image))?;
            accepted.store(true, Ordering::Release);
            output.write(handle);
            Ok(PODOCO_OK)
        })
    }
}
/// Return schema-v0 image metadata without exposing writable pixels.
/// # Safety
/// Outputs satisfy podoco_buffer_view's contract.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn podoco_image_info(
    image: PodocoHandle,
    output: *mut PodocoHandle,
    error: *mut PodocoHandle,
) -> PodocoStatus {
    // SAFETY: Exported output contract.
    unsafe {
        guard(error, || {
            clear(output)?;
            let entry = handles::get(image, Kind::Image)?;
            let Entry::Image(image) = entry.as_ref() else {
                unreachable!()
            };
            output.write(buffer(&serde_json::json!({"schema_version":0,"image":image.descriptor(),"retained_bytes":image.retained_bytes()}),PODOCO_MAX_METADATA_BYTES)?);
            Ok(PODOCO_OK)
        })
    }
}

#[derive(Deserialize)]
struct Open {
    schema_version: u32,
    bundle_directory: String,
    options: AnalyzerOptions,
    formula_bundle_directory: Option<String>,
    formula_options: Option<podoco::formula::FormulaOptions>,
}
/// Verify an existing offline bundle and open one persistent analyzer. Blocks;
/// bindings must call on a worker. Metadata is UTF-8 JSON with schema_version=0,
/// bundle_directory, and the complete Rust AnalyzerOptions representation.
/// With PODOCO_FEATURE_FORMULA, optional formula_bundle_directory enables
/// recognition; formula_options is a token cap integer (1..=2048, default 2048).
/// # Safety
/// Config covers readable bytes for this call; outputs satisfy the standard
/// disjoint writable contract. Normal builds never download models.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn podoco_analyzer_open(
    config: PodocoBytes,
    output: *mut PodocoHandle,
    error: *mut PodocoHandle,
) -> PodocoStatus {
    // SAFETY: Exported borrowed-input/output contract.
    unsafe {
        guard(error, || {
            clear(output)?;
            let config: Open = json(config)?;
            schema(config.schema_version)?;
            if config.formula_options.is_some() && config.formula_bundle_directory.is_none() {
                return Err(invalid("formula_options requires a formula bundle"));
            }
            let bundle = ModelBundle::verify(&config.bundle_directory)?;
            let mut model_manifests = vec![bundle.manifest_sha256().clone()];
            let limits = config.options.limits;
            let analyzer = if let Some(path) = config.formula_bundle_directory {
                let formula = podoco::formula::FormulaBundle::verify(path)?;
                model_manifests.push(formula.manifest_sha256().clone());
                Analyzer::open_with_formula(
                    bundle,
                    formula,
                    config.options,
                    config.formula_options.unwrap_or_default(),
                )?
            } else {
                Analyzer::open(bundle, config.options)?
            };
            let profile = analyzer.profile().to_owned();
            output.write(handles::insert(Entry::Analyzer(Box::new(OwnedAnalyzer {
                analyzer,
                limits,
                profile,
                model_manifests,
            })))?);
            Ok(PODOCO_OK)
        })
    }
}
/// Read schema-v0 loaded-model capabilities and the exact analysis profile ID.
/// # Safety
/// Outputs satisfy podoco_buffer_view's contract.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn podoco_analyzer_info(
    analyzer: PodocoHandle,
    output: *mut PodocoHandle,
    error: *mut PodocoHandle,
) -> PodocoStatus {
    // SAFETY: Exported output contract.
    unsafe {
        guard(error, || {
            clear(output)?;
            let entry = handles::get(analyzer, Kind::Analyzer)?;
            let Entry::Analyzer(a) = entry.as_ref() else {
                unreachable!()
            };
            output.write(buffer(&serde_json::json!({"schema_version":0,"capabilities":a.analyzer.capabilities(),"profile":a.profile,"limits":a.limits,"model_manifests":a.model_manifests}),PODOCO_MAX_METADATA_BYTES)?);
            Ok(PODOCO_OK)
        })
    }
}
/// Cancel and drain analyzer jobs/native work. Blocks; keep source/result pumps
/// running until it returns. Repeated calls succeed. Release the handle later.
/// # Safety
/// The optional error output satisfies podoco_buffer_view's contract.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn podoco_analyzer_close(
    analyzer: PodocoHandle,
    error: *mut PodocoHandle,
) -> PodocoStatus {
    // SAFETY: Exported error output contract.
    unsafe {
        guard(error, || {
            let entry = handles::get(analyzer, Kind::Analyzer)?;
            let Entry::Analyzer(a) = entry.as_ref() else {
                unreachable!()
            };
            a.analyzer.close()?;
            Ok(PODOCO_OK)
        })
    }
}

/// Verify an existing offline bundle and return schema-v0 identity/profile,
/// manifest hash, and declared capabilities. This blocks on local hashing; use a
/// worker. Analyzer opening verifies again before loading immutable artifacts.
/// # Safety
/// Directory is length-delimited readable UTF-8; outputs follow the standard
/// contract. No download/compilation occurs during verification.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn podoco_bundle_verify(
    directory: PodocoBytes,
    output: *mut PodocoHandle,
    error: *mut PodocoHandle,
) -> PodocoStatus {
    // SAFETY: Exported input/output contract.
    unsafe {
        guard(error, || {
            clear(output)?;
            let path = std::str::from_utf8(input(directory, PODOCO_MAX_METADATA_BYTES)?)
                .map_err(|_| invalid("bundle path is not UTF-8"))?;
            let bundle = ModelBundle::verify(path)?;
            output.write(buffer(
                &serde_json::json!({"schema_version":0,"id":bundle.manifest().id,
            "profile":bundle.manifest().profile.id,"manifest_sha256":bundle.manifest_sha256(),
            "capabilities":bundle.declared_capabilities()}),
                PODOCO_MAX_METADATA_BYTES,
            )?);
            Ok(PODOCO_OK)
        })
    }
}

/// Verify the pinned formula bundle offline and return schema-v0 identity/profile
/// and manifest hash. Probe PODOCO_FEATURE_FORMULA before using this ABI-2 extension.
/// # Safety
/// Directory is readable UTF-8 for this call; output/error handles are writable,
/// aligned and disjoint. This blocks on hashing and never downloads or compiles.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn podoco_formula_bundle_verify(
    directory: PodocoBytes,
    output: *mut PodocoHandle,
    error: *mut PodocoHandle,
) -> PodocoStatus {
    // SAFETY: Exported borrowed-input and disjoint writable-output contracts.
    unsafe {
        guard(error, || {
            clear(output)?;
            let path = std::str::from_utf8(input(directory, PODOCO_MAX_METADATA_BYTES)?)
                .map_err(|_| invalid("bundle path is not UTF-8"))?;
            let bundle = podoco::formula::FormulaBundle::verify(path)?;
            output.write(buffer(&serde_json::json!({"schema_version":0,"id":bundle.manifest().id,"profile":bundle.manifest().profile,
            "manifest_sha256":bundle.manifest_sha256()}),PODOCO_MAX_METADATA_BYTES)?);
            Ok(PODOCO_OK)
        })
    }
}
