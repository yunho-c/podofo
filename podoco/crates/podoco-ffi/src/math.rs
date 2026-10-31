//! Independent optional math worker transport. No analysis/model handle required.
#[cfg(feature = "math")]
use crate::handles::{self, Entry, Kind};
use crate::{types::*, wire::*};
#[cfg(feature = "math")]
use podoco::math::{MathInput, MathLimits, MathProcessor, MathRules, MathSpeechOptions};

#[cfg(not(feature = "math"))]
fn unsupported() -> podoco::Error {
    podoco::Error::new(
        podoco::ErrorCode::UnsupportedCapability,
        "build with math to convert mathematical expressions",
    )
}

/// Verify the exact offline rule inventory. Require PODOCO_FEATURE_MATH before
/// resolving any math extension export. Blocks on filesystem hashing.
/// # Safety
/// Directory covers readable UTF-8; output/error are aligned, writable, disjoint.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn podoco_math_rules_verify(
    directory: PodocoBytes,
    output: *mut PodocoHandle,
    error: *mut PodocoHandle,
) -> PodocoStatus {
    // SAFETY: Exported borrowed-input and disjoint writable-output contracts.
    unsafe {
        guard(error, || {
            clear(output)?;
            #[cfg(not(feature = "math"))]
            {
                let _ = directory;
                Err(unsupported())
            }
            #[cfg(feature = "math")]
            {
                let path = std::str::from_utf8(input(directory, PODOCO_MAX_METADATA_BYTES)?)
                    .map_err(|_| invalid("rule path is not UTF-8"))?;
                let rules = MathRules::verify(path)?;
                output.write(buffer(&serde_json::json!({"schema_version":0,"id":rules.id(),"profile":rules.profile(),"manifest_sha256":rules.manifest_sha256()}),PODOCO_MAX_METADATA_BYTES)?);
                Ok(PODOCO_OK)
            }
        })
    }
}

#[cfg(feature = "math")]
#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct Open {
    schema_version: u32,
    rules_directory: String,
    limits: MathLimits,
}
/// Open a math processor with schema-v0 {rules_directory,limits}. This verifies
/// assets again, owns a separate conversion worker, and never loads ML models.
/// # Safety
/// Config covers readable bytes; output/error are aligned, writable, disjoint.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn podoco_math_open(
    config: PodocoBytes,
    output: *mut PodocoHandle,
    error: *mut PodocoHandle,
) -> PodocoStatus {
    // SAFETY: Exported borrowed-input and disjoint writable-output contracts.
    unsafe {
        guard(error, || {
            clear(output)?;
            #[cfg(not(feature = "math"))]
            {
                let _ = config;
                Err(unsupported())
            }
            #[cfg(feature = "math")]
            {
                let config: Open = json(config)?;
                schema(config.schema_version)?;
                let processor = MathProcessor::open(
                    MathRules::verify(&config.rules_directory)?,
                    config.limits,
                )?;
                output.write(handles::insert(Entry::Math(Box::new(processor)))?);
                Ok(PODOCO_OK)
            }
        })
    }
}

/// Read schema-v0 effective limits, rule/profile identities and language/style availability.
/// # Safety
/// Output/error are aligned, writable, disjoint; handles may be arbitrary IDs.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn podoco_math_info(
    processor: PodocoHandle,
    output: *mut PodocoHandle,
    error: *mut PodocoHandle,
) -> PodocoStatus {
    // SAFETY: Exported writable-output contract.
    unsafe {
        guard(error, || {
            clear(output)?;
            #[cfg(not(feature = "math"))]
            {
                let _ = processor;
                Err(unsupported())
            }
            #[cfg(feature = "math")]
            {
                let entry = handles::get(processor, Kind::Math)?;
                let Entry::Math(p) = entry.as_ref() else {
                    unreachable!()
                };
                output.write(buffer(&serde_json::json!({"schema_version":0,"limits":p.limits(),"rules_id":p.rules().id(),"profile":p.rules().profile(),"rules_manifest_sha256":p.rules().manifest_sha256(),"languages":p.languages()}),PODOCO_MAX_METADATA_BYTES)?);
                Ok(PODOCO_OK)
            }
        })
    }
}

#[cfg(feature = "math")]
#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct Convert {
    schema_version: u32,
    input: MathInput,
    speech_options: Option<MathSpeechOptions>,
}
/// Blocking conversion: schema-v0 {input,speech_options?}. Without speech options
/// returns {schema_version:0,kind:"mathml",value}; with them kind is "speech".
/// Call off UI threads; a full processor queue returns limit_exceeded.
/// # Safety
/// Config covers readable bytes; output/error are aligned, writable, disjoint.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn podoco_math_convert(
    processor: PodocoHandle,
    config: PodocoBytes,
    output: *mut PodocoHandle,
    error: *mut PodocoHandle,
) -> PodocoStatus {
    // SAFETY: Exported borrowed-input and disjoint writable-output contracts.
    unsafe {
        guard(error, || {
            clear(output)?;
            #[cfg(not(feature = "math"))]
            {
                let _ = (processor, config);
                Err(unsupported())
            }
            #[cfg(feature = "math")]
            {
                let request: Convert = json(config)?;
                schema(request.schema_version)?;
                let entry = handles::get(processor, Kind::Math)?;
                let Entry::Math(p) = entry.as_ref() else {
                    unreachable!()
                };
                let result = match request.speech_options {
                    Some(options) => {
                        serde_json::json!({"schema_version":0,"kind":"speech","value":p.to_speech(request.input,options)?})
                    }
                    None => {
                        serde_json::json!({"schema_version":0,"kind":"mathml","value":p.to_mathml(request.input)?})
                    }
                };
                output.write(buffer(&result, PODOCO_MAX_METADATA_BYTES)?);
                Ok(PODOCO_OK)
            }
        })
    }
}

/// Cancel queued conversions and drain active work. Idempotent; release the
/// processor handle afterward. Other analyzers/math/TTS workers are independent.
/// # Safety
/// Error is null or aligned writable storage; it is disjoint from other outputs.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn podoco_math_close(
    processor: PodocoHandle,
    error: *mut PodocoHandle,
) -> PodocoStatus {
    // SAFETY: Exported writable-error contract.
    unsafe {
        guard(error, || {
            #[cfg(not(feature = "math"))]
            {
                let _ = processor;
                Err(unsupported())
            }
            #[cfg(feature = "math")]
            {
                let entry = handles::get(processor, Kind::Math)?;
                let Entry::Math(p) = entry.as_ref() else {
                    unreachable!()
                };
                p.close()?;
                Ok(PODOCO_OK)
            }
        })
    }
}
