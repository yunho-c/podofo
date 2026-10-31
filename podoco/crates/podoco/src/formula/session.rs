//! Blocking single-crop calls with reusable, thread-confined native models.
use super::{FormulaBundle, bundle::PROFILE};
use crate::{
    AnalyzerOptions, Error, ErrorCode, FormulaOutcome, PageInput, ProfileId, Rect, RegionId,
    Result,
    results::{FormulaDisplayKind, ModelProvenance, PipelineProvenance},
};
use serde::{Deserialize, Serialize};
use std::{
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
        mpsc::{self, SyncSender},
    },
    thread::JoinHandle,
    time::Instant,
};

/// An original-resolution raster and an explicitly identified formula region.
#[derive(Clone, Debug)]
pub struct FormulaInput {
    /// Source page, raster mapping and rendering provenance.
    pub page: PageInput,
    /// Local region identity, preserved by the caller when applying the outcome.
    pub region_id: RegionId,
    /// Canonical page-space bounds, mapped to a covering raster crop.
    pub bounds: Rect,
    /// Detector or caller supplied context; never inferred from crop size.
    pub display_kind: FormulaDisplayKind,
}
/// Bounded greedy generation. Lower caps are recorded in outcome provenance.
#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
#[serde(try_from = "u32", into = "u32")]
pub struct FormulaOptions {
    max_new_tokens: u32,
}
impl FormulaOptions {
    /// Set a positive cap no larger than the deployed 2048-token cache.
    pub fn new(max_new_tokens: u32) -> Result<Self> {
        if !(1..=2048).contains(&max_new_tokens) {
            return Err(Error::input("formula token cap must be 1..=2048"));
        }
        Ok(Self { max_new_tokens })
    }
    /// Effective generated-token cap, excluding the start token.
    pub fn max_new_tokens(self) -> u32 {
        self.max_new_tokens
    }
}
impl Default for FormulaOptions {
    fn default() -> Self {
        Self {
            max_new_tokens: 2048,
        }
    }
}
impl TryFrom<u32> for FormulaOptions {
    type Error = Error;
    fn try_from(v: u32) -> Result<Self> {
        Self::new(v)
    }
}
impl From<FormulaOptions> for u32 {
    fn from(v: FormulaOptions) -> u32 {
        v.max_new_tokens
    }
}
/// Cloneable cancellation signal checked before encoding and between tokens.
#[derive(Clone, Default, Debug)]
pub struct FormulaCancellation(Arc<AtomicBool>);
impl FormulaCancellation {
    /// Request cancellation; native calls already in progress drain first.
    pub fn cancel(&self) {
        self.0.store(true, Ordering::Release);
    }
    /// Whether cancellation has been requested.
    pub fn is_cancelled(&self) -> bool {
        self.0.load(Ordering::Acquire)
    }
}
/// Session observations; excludes opaque Core ML model/workspace allocations.
#[derive(Clone, Debug, Default, Serialize)]
pub struct FormulaSessionStats {
    /// Loaded encoder plus two decoder graphs.
    pub model_loads: u64,
    /// Completed generation attempts, including token-limited results.
    pub generations: u64,
    /// Last generated IDs, including the start token, for qualification diagnostics.
    pub last_token_ids: Vec<u32>,
    /// Last ByteLevel decoded text, before processor normalization.
    pub last_raw_text: String,
    /// Cache promotions performed by completed attempts.
    pub cache_promotions: u64,
    /// Maximum SDK-visible decoder state and promotion scratch bytes.
    pub peak_decoder_cache_bytes: u64,
    /// Conservative host buffer reservation plus measured native spans and preprocessing scratch.
    pub peak_tensor_bytes: u64,
    /// Blocking opening seconds, excluding prior verification.
    pub open_seconds: f64,
    /// Last preprocessing wall seconds.
    pub preprocessing_seconds: f64,
    /// Last encoder/decoder wall seconds, including cache initialization/promotion.
    pub generation_seconds: f64,
    /// Last complete blocking recognition call seconds.
    pub total_seconds: f64,
}
type Cancel = Box<dyn Fn() -> bool + Send>;
type Reply = SyncSender<(Result<FormulaOutcome>, FormulaSessionStats, bool)>;
#[cfg_attr(not(feature = "coreml"), allow(dead_code))]
struct Request {
    input: FormulaInput,
    options: FormulaOptions,
    cancel: Cancel,
    reply: Reply,
}
/// Reuses model graphs while creating fresh state for every expression.
/// Mutable access serializes calls; drop/close joins the native owner thread.
pub struct FormulaSession {
    sender: Option<SyncSender<Request>>,
    worker: Option<JoinHandle<()>>,
    options: AnalyzerOptions,
    stats: FormulaSessionStats,
    failed: bool,
}
impl FormulaSession {
    /// Load and validate all graph interfaces before accepting a crop.
    pub fn open(bundle: FormulaBundle, options: AnalyzerOptions) -> Result<Self> {
        #[cfg(not(feature = "coreml"))]
        {
            let _ = (bundle, options);
            Err(Error::new(
                ErrorCode::UnsupportedCapability,
                "build with coreml to recognize formulas",
            ))
        }
        #[cfg(feature = "coreml")]
        {
            use super::{preprocess, text};
            use crate::results::RecognizedFormula;
            use crate::runtime::coreml::{
                self,
                formula::{CACHE_PEAK, FormulaModel, NATIVE_TENSORS},
            };
            // Includes pixels, logits, masks, tokenizer parsing and bounded text
            // normalization scratch. Embedding tables remain file-backed, not copied.
            const HOST: u64 = 16 * 1024 * 1024;
            if options.limits.tensor_bytes() < 64 * 1024 * 1024
                || options.limits.decoder_cache_bytes() < CACHE_PEAK
            {
                return Err(Error::new(
                    ErrorCode::LimitExceeded,
                    format!(
                        "formula recognition requires 64 MiB tensor and {CACHE_PEAK} decoder cache bytes"
                    ),
                ));
            }
            let start = Instant::now();
            let (sender, receiver) = mpsc::sync_channel::<Request>(1);
            let (ready, opened) = mpsc::sync_channel(1);
            let worker_options = options.clone();
            let worker = std::thread::Builder::new()
                .name("podoco-formula".into())
                .spawn(move || {
                    coreml::pool(|| {
                        let loaded = (|| -> Result<_> {
                            let native = FormulaModel::load(
                                &bundle,
                                worker_options.compute_policy,
                                NATIVE_TENSORS,
                                worker_options.limits.decoder_cache_bytes(),
                            )?;
                            let text = text::Decoder::load(
                                &bundle.directory().join("checkpoint/tokenizer.json"),
                            )?;
                            Ok((native, text))
                        })();
                        let (mut native, text) = match loaded {
                            Ok(v) => v,
                            Err(e) => {
                                let _ = ready.send(Err(e));
                                return;
                            }
                        };
                        let mut pixels = vec![0f32; preprocess::LEN];
                        let mut stats = FormulaSessionStats {
                            model_loads: 3,
                            ..Default::default()
                        };
                        if ready.send(Ok(())).is_err() {
                            return;
                        }
                        while let Ok(Request {
                            input,
                            options,
                            cancel,
                            reply,
                        }) = receiver.recv()
                        {
                            stats.last_token_ids.clear();
                            stats.last_raw_text.clear();
                            stats.preprocessing_seconds = 0.;
                            stats.generation_seconds = 0.;
                            let result = (|| -> Result<FormulaOutcome> {
                                if cancel() {
                                    return Err(Error::new(
                                        ErrorCode::Cancelled,
                                        "formula recognition cancelled",
                                    ));
                                }
                                let d = input.page.image().descriptor();
                                let crop = input.page.pixel_to_page().crop_pixels(
                                    input.bounds,
                                    d.width(),
                                    d.height(),
                                )?;
                                let start = Instant::now();
                                let scratch = preprocess::run(
                                    input.page.image(),
                                    crop,
                                    &mut pixels,
                                    worker_options.limits.tensor_bytes() - HOST - NATIVE_TENSORS,
                                )?;
                                stats.preprocessing_seconds = start.elapsed().as_secs_f64();
                                stats.peak_tensor_bytes =
                                    stats.peak_tensor_bytes.max(HOST + scratch + NATIVE_TENSORS);
                                let start = Instant::now();
                                let generated = native.generate(
                                    &pixels,
                                    options.max_new_tokens as usize,
                                    cancel.as_ref(),
                                )?;
                                stats.generation_seconds = start.elapsed().as_secs_f64();
                                stats.generations += 1;
                                stats.cache_promotions += u64::from(generated.promotions);
                                stats.peak_decoder_cache_bytes =
                                    stats.peak_decoder_cache_bytes.max(generated.cache_peak);
                                stats.peak_tensor_bytes =
                                    stats.peak_tensor_bytes.max(HOST + generated.native_peak);
                                stats.last_token_ids = generated.ids;
                                let (raw, latex) = text.decode(&stats.last_token_ids)?;
                                stats.last_raw_text = raw;
                                let provenance =
                                    provenance(&bundle, worker_options.compute_policy, options)?;
                                if stats.last_token_ids.last() != Some(&2) {
                                    return Ok(FormulaOutcome::Truncated {
                                        partial_latex: (!latex.is_empty()).then_some(latex),
                                        error: Error::new(
                                            ErrorCode::LimitExceeded,
                                            "formula reached its generated-token cap before EOS",
                                        ),
                                        provenance,
                                    });
                                }
                                if latex.trim().is_empty() {
                                    return Ok(FormulaOutcome::Failed {
                                        error: Error::new(
                                            ErrorCode::Recognition,
                                            "formula decoded to empty text",
                                        ),
                                    });
                                }
                                Ok(FormulaOutcome::Recognized {
                                    formula: RecognizedFormula {
                                        latex,
                                        display_kind: input.display_kind,
                                        score: None,
                                        provenance,
                                    },
                                })
                            })();
                            let result = result
                                .or_else(|error| {
                                    if error.code == ErrorCode::LimitExceeded {
                                        Ok(FormulaOutcome::Truncated {
                                            partial_latex: None,
                                            error,
                                            provenance: provenance(
                                                &bundle,
                                                worker_options.compute_policy,
                                                options,
                                            )?,
                                        })
                                    } else {
                                        Err(error)
                                    }
                                })
                                .and_then(|outcome| {
                                    outcome.to_json(
                                        worker_options
                                            .limits
                                            .max_update_bytes()
                                            .min(usize::MAX as u64)
                                            as usize,
                                    )?;
                                    Ok(outcome)
                                });
                            let fatal = result.as_ref().is_err_and(|e| {
                                matches!(
                                    e.code,
                                    ErrorCode::Backend | ErrorCode::Io | ErrorCode::InvalidAsset
                                )
                            });
                            drop(input);
                            if reply.send((result, stats.clone(), fatal)).is_err() || fatal {
                                break;
                            }
                        }
                    })
                })
                .map_err(|e| Error::new(ErrorCode::WorkerFailed, e.to_string()))?;
            match opened.recv() {
                Ok(Ok(())) => Ok(Self {
                    sender: Some(sender),
                    worker: Some(worker),
                    options,
                    stats: FormulaSessionStats {
                        model_loads: 3,
                        open_seconds: start.elapsed().as_secs_f64(),
                        ..Default::default()
                    },
                    failed: false,
                }),
                other => {
                    let _ = worker.join();
                    Err(other
                        .ok()
                        .and_then(|v| v.err())
                        .unwrap_or_else(worker_failed))
                }
            }
        }
    }
    /// Recognize the region from the original page raster. The result owns no pixels.
    pub fn recognize(
        &mut self,
        input: FormulaInput,
        options: FormulaOptions,
        cancel: FormulaCancellation,
    ) -> Result<FormulaOutcome> {
        self.recognize_with_cancel(input, options, Box::new(move || cancel.is_cancelled()))
    }
    pub(crate) fn recognize_with_cancel(
        &mut self,
        input: FormulaInput,
        options: FormulaOptions,
        cancel: Cancel,
    ) -> Result<FormulaOutcome> {
        if self.failed {
            return Err(worker_failed());
        }
        let sender = self
            .sender
            .as_ref()
            .ok_or_else(|| Error::input("formula session is closed"))?;
        if input.page.image().retained_bytes() as u64 > self.options.limits.input_bytes() {
            return Err(Error::new(
                ErrorCode::LimitExceeded,
                "formula page exceeds input budget",
            ));
        }
        let start = Instant::now();
        let (reply, receiver) = mpsc::sync_channel(1);
        sender
            .send(Request {
                input,
                options,
                cancel,
                reply,
            })
            .map_err(|_| {
                self.failed = true;
                worker_failed()
            })?;
        let (result, mut stats, fatal) = receiver.recv().map_err(|_| {
            self.failed = true;
            worker_failed()
        })?;
        stats.open_seconds = self.stats.open_seconds;
        stats.total_seconds = start.elapsed().as_secs_f64();
        self.stats = stats;
        self.failed = fatal;
        result
    }
    /// Whether a native failure or unexpected worker exit has ended this session.
    pub fn failed(&self) -> bool {
        self.failed
    }
    /// Owned qualification observations from completed requests.
    pub fn stats(&self) -> &FormulaSessionStats {
        &self.stats
    }
    /// Wait for native release; repeated calls succeed after cleanup.
    pub fn close(&mut self) -> Result<()> {
        self.sender.take();
        if self.worker.take().is_some_and(|w| w.join().is_err()) {
            self.failed = true;
            return Err(worker_failed());
        }
        Ok(())
    }
}
impl Drop for FormulaSession {
    fn drop(&mut self) {
        let _ = self.close();
    }
}
fn worker_failed() -> Error {
    Error::new(ErrorCode::WorkerFailed, "formula worker terminated")
}
#[cfg_attr(not(feature = "coreml"), allow(dead_code))]
fn provenance(
    bundle: &FormulaBundle,
    policy: crate::options::ComputePolicy,
    options: FormulaOptions,
) -> Result<PipelineProvenance> {
    let profile = if options.max_new_tokens == 2048 {
        PROFILE.to_string()
    } else {
        format!("{PROFILE}-cap{}", options.max_new_tokens)
    };
    Ok(PipelineProvenance {
        sdk_version: ProfileId::new(crate::VERSION)?,
        backend: ProfileId::new("coreml")?,
        compute_policy: policy,
        adapter: ProfileId::new("pp-formulanet-plus-l-v1")?,
        profile: ProfileId::new(profile)?,
        models: vec![ModelProvenance {
            model_id: ProfileId::new(&bundle.manifest().id)?,
            manifest_sha256: bundle.manifest_sha256().clone(),
            artifacts: bundle
                .manifest()
                .files
                .iter()
                .map(|f| (f.path.clone(), f.sha256.clone()))
                .collect(),
        }],
    })
}
