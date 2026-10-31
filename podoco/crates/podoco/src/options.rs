//! Explicit capabilities and finite budgets; no model-quality defaults are implied.
use crate::{Error, ErrorCode, ProfileId, Result};
use serde::{Deserialize, Serialize};

/// Which detected formulas should be recognized.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FormulaScope {
    /// Process all detected inline, displayed, and unknown-kind formulas.
    #[default]
    All,
    /// Layout-only analysis; recognition is explicitly not requested.
    None,
}
/// Core ML compute-unit permission, not observed device placement.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ComputePolicy {
    /// CPU-only diagnostic/control execution.
    CpuOnly,
    /// Permit CPU and Apple Neural Engine.
    CpuAndNeuralEngine,
    /// Permit all Core ML compute units.
    All,
}
/// Functional capabilities, separate from availability and measured placement.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Capabilities {
    /// Layout detection.
    pub layout: bool,
    /// Formula crop recognition.
    pub formula_recognition: bool,
    /// Qualified polygon decoding.
    pub polygons: bool,
    /// Model-supported reading order.
    pub reading_order: bool,
}
impl Capabilities {
    /// Reject unsupported page-analysis requests before source rendering.
    pub fn validate(&self, options: &AnalysisOptions) -> Result<()> {
        if !self.layout {
            return Err(unsupported("layout"));
        }
        if options.formula_scope == FormulaScope::All {
            self.require_recognizer()?;
        }
        if options.require_polygons && !self.polygons {
            return Err(unsupported("polygons"));
        }
        if options.require_reading_order && !self.reading_order {
            return Err(unsupported("reading order"));
        }
        Ok(())
    }
    /// Validate formula-only work without requiring a detector.
    pub fn require_recognizer(&self) -> Result<()> {
        if self.formula_recognition {
            Ok(())
        } else {
            Err(unsupported("formula recognition"))
        }
    }
}
fn unsupported(name: &str) -> Error {
    Error::new(
        ErrorCode::UnsupportedCapability,
        format!("bundle does not support {name}"),
    )
}

/// Immutable per-job options after the caller's snapshot is accepted.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct AnalysisOptions {
    /// Qualified pipeline profile; unsupported overrides are not accepted in M1.
    pub profile: ProfileId,
    /// All detections by default, including unknown display kind.
    #[serde(default)]
    pub formula_scope: FormulaScope,
    /// Require polygons instead of accepting their absence.
    #[serde(default)]
    pub require_polygons: bool,
    /// Require model-supported reading order.
    #[serde(default)]
    pub require_reading_order: bool,
}
impl AnalysisOptions {
    /// Use the given profile and request all detected formulas.
    pub fn new(profile: ProfileId) -> Self {
        Self {
            profile,
            formula_scope: FormulaScope::All,
            require_polygons: false,
            require_reading_order: false,
        }
    }
}

/// Explicit finite resource limits. No production defaults are selected by M1.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(try_from = "LimitsWire", into = "LimitsWire")]
pub struct ResourceLimits(LimitsWire);
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
struct LimitsWire {
    queued_jobs: u32,
    input_bytes: u64,
    pending_updates: u32,
    result_bytes: u64,
    max_update_bytes: u64,
    tensor_bytes: u64,
    decoder_cache_bytes: u64,
}
impl ResourceLimits {
    /// Set positive limits; a single update must fit the total result budget.
    pub fn new(
        queued_jobs: u32,
        input_bytes: u64,
        pending_updates: u32,
        result_bytes: u64,
        max_update_bytes: u64,
        tensor_bytes: u64,
        decoder_cache_bytes: u64,
    ) -> Result<Self> {
        Self::try_from(LimitsWire {
            queued_jobs,
            input_bytes,
            pending_updates,
            result_bytes,
            max_update_bytes,
            tensor_bytes,
            decoder_cache_bytes,
        })
    }
    /// Maximum queued job count.
    pub fn queued_jobs(self) -> u32 {
        self.0.queued_jobs
    }
    /// Total retained input allocation budget, including padding.
    pub fn input_bytes(self) -> u64 {
        self.0.input_bytes
    }
    /// Maximum pending semantic update count.
    pub fn pending_updates(self) -> u32 {
        self.0.pending_updates
    }
    /// Total queued serialized-result budget.
    pub fn result_bytes(self) -> u64 {
        self.0.result_bytes
    }
    /// Maximum size of an individual encoded update.
    pub fn max_update_bytes(self) -> u64 {
        self.0.max_update_bytes
    }
    /// Native tensor allocation budget, including unwanted exported outputs.
    pub fn tensor_bytes(self) -> u64 {
        self.0.tensor_bytes
    }
    /// Recognition cache allocation budget; unused by a layout-only pipeline.
    pub fn decoder_cache_bytes(self) -> u64 {
        self.0.decoder_cache_bytes
    }
}
impl TryFrom<LimitsWire> for ResourceLimits {
    type Error = Error;
    fn try_from(v: LimitsWire) -> Result<Self> {
        if v.queued_jobs == 0
            || v.pending_updates == 0
            || [
                v.input_bytes,
                v.result_bytes,
                v.max_update_bytes,
                v.tensor_bytes,
                v.decoder_cache_bytes,
            ]
            .contains(&0)
            || v.max_update_bytes > v.result_bytes
        {
            return Err(Error::input(
                "budgets must be positive; max_update_bytes must fit result_bytes",
            ));
        }
        Ok(Self(v))
    }
}
impl From<ResourceLimits> for LimitsWire {
    fn from(v: ResourceLimits) -> Self {
        v.0
    }
}

/// Construction policy for a future analyzer; creation does not load a backend.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct AnalyzerOptions {
    /// Explicit compute permission; no silent backend fallback.
    pub compute_policy: ComputePolicy,
    /// Explicit finite limits.
    pub limits: ResourceLimits,
}
