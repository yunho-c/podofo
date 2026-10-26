//! Owned domain results and bounded versioned JSON transport. Pixels stay out of this schema.
use crate::{
    AnalysisId, DocumentRef, Error, ErrorCode, PageDescriptor, PageKey, ProfileId, RegionId, Result,
};
use crate::{
    domain::{Score, Sha256Digest},
    geometry::{Affine, Polygon, Rect},
    image::ImageDescriptor,
    options::{ComputePolicy, FormulaScope},
};
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, HashSet},
    io::Write,
};

/// Result schema version, independent of the C ABI and package versions.
pub const RESULT_SCHEMA_VERSION: u32 = 0;

/// Compact cross-model categories. Preserve source labels even for known categories.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RegionCategory {
    /// Prose and specialized text, including references and footnotes.
    Text,
    /// Document or section heading.
    Heading,
    /// Mathematical content requiring crop recognition.
    Formula,
    /// Equation-number region, separate from its formula.
    FormulaNumber,
    /// Table region; no table-content extraction is implied.
    Table,
    /// Image or chart.
    Figure,
    /// Figure caption.
    Caption,
    /// Page header, possibly image content.
    Header,
    /// Page footer, possibly image content.
    Footer,
    /// Unsupported or intentionally unnormalized class.
    Other,
}
/// Model-supplied formula display context; unknown never means absent.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FormulaDisplayKind {
    /// Embedded in surrounding text.
    Inline,
    /// Separate displayed equation.
    Displayed,
    /// The source model cannot distinguish display context.
    Unknown,
}
/// A portable nonfatal observation, distinct from an outcome failure.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Diagnostic {
    /// Stable producer-defined diagnostic identity.
    pub code: ProfileId,
    /// Human-readable context; no model tensors or native handles.
    pub message: String,
}
/// Exact model evidence used by a pipeline.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ModelProvenance {
    /// Versioned model identity.
    pub model_id: ProfileId,
    /// Raw bundle manifest SHA-256, not a claim of publisher authenticity.
    pub manifest_sha256: Sha256Digest,
    /// Model payload names and hashes, including compiled weights.
    pub artifacts: BTreeMap<String, Sha256Digest>,
}
/// Effective pipeline settings. Compute permission is not measured placement.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PipelineProvenance {
    /// Podoco version used for execution.
    pub sdk_version: ProfileId,
    /// Backend identity, initially `coreml`.
    pub backend: ProfileId,
    /// Explicit compute-unit policy.
    pub compute_policy: ComputePolicy,
    /// Versioned adapter implementation.
    pub adapter: ProfileId,
    /// Versioned preprocessing/decoding profile and effective options.
    pub profile: ProfileId,
    /// Exact models selected for the pipeline. A progressive layout snapshot
    /// can precede recognition; formula outcomes identify their own recognizer.
    pub models: Vec<ModelProvenance>,
}
impl PipelineProvenance {
    fn validate(&self) -> Result<()> {
        if self.models.is_empty()
            || self
                .models
                .iter()
                .any(|m| m.artifacts.is_empty() || m.artifacts.keys().any(|k| k.trim().is_empty()))
        {
            return Err(Error::result(
                "pipeline provenance needs model artifact hashes",
            ));
        }
        Ok(())
    }
}
/// Rendering and layout provenance for a page.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct PageProvenance {
    /// Layout model and processing policy.
    pub pipeline: PipelineProvenance,
    /// Application rendering profile, including background and annotation policy.
    pub render_profile: ProfileId,
    /// Original raster descriptor; no pixel payload.
    pub image: ImageDescriptor,
    /// Original pixel-edge to canonical page transform.
    pub pixel_to_page: Affine,
}
/// One detected region, with source identity preserved independently of normalization.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct LayoutRegion {
    /// Local stable region identity, not a cross-run object identifier.
    pub id: RegionId,
    /// Cross-model category.
    pub category: RegionCategory,
    /// Original numeric model class.
    pub model_class_id: u32,
    /// Original model label, including collapsed labels.
    pub model_label: String,
    /// Native subtype from a pinned source map when available.
    pub native_subtype: Option<String>,
    /// Required for formulas, absent for other categories.
    pub display_kind: Option<FormulaDisplayKind>,
    /// Axis-aligned canonical page bounds.
    pub bounds: Rect,
    /// Optional qualified page-space polygon.
    pub polygon: Option<Polygon>,
    /// Optional detector score with model-specific semantics.
    pub score: Option<Score>,
    /// Nonfatal adapter observations.
    pub diagnostics: Vec<Diagnostic>,
}
impl LayoutRegion {
    fn validate(&self) -> Result<()> {
        if self.model_label.trim().is_empty()
            || (self.category == RegionCategory::Formula) != self.display_kind.is_some()
        {
            return Err(Error::result(
                "region needs a label and formula-only display context",
            ));
        }
        Ok(())
    }
}
/// Successful recognized LaTeX, retained exactly as decoded by the adapter.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct RecognizedFormula {
    /// Original LaTeX; no application-side rewriting.
    pub latex: String,
    /// Detector or explicitly supplied crop context.
    pub display_kind: FormulaDisplayKind,
    /// Optional recognizer score; independent of detector confidence.
    pub score: Option<Score>,
    /// Model, token-decoding profile, and execution policy.
    pub provenance: PipelineProvenance,
}
/// A terminal formula outcome; truncated output is never a recognized formula.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "status", rename_all = "snake_case")]
pub enum FormulaOutcome {
    /// Recognition succeeded.
    Recognized {
        /// Complete owned recognized expression.
        formula: RecognizedFormula,
    },
    /// Recognition failed while other formulas/pages may continue.
    Failed {
        /// Owned failure.
        error: Error,
    },
    /// A generation or resource limit prevented completion.
    Truncated {
        /// Diagnostic partial output, never successful copy/listen content.
        partial_latex: Option<String>,
        /// Limit or stopping condition that prevented completion.
        error: Error,
        /// Recognizer and decoding policy.
        provenance: PipelineProvenance,
    },
}
impl FormulaOutcome {
    /// Validate and encode a formula using a bounded output allocation.
    pub fn to_json(&self, max_bytes: usize) -> Result<Vec<u8>> {
        self.validate()?;
        let mut writer = BoundedWriter {
            bytes: Vec::new(),
            limit: max_bytes,
            exceeded: false,
        };
        serde_json::to_writer(&mut writer, self).map_err(|e| {
            Error::new(
                if writer.exceeded {
                    ErrorCode::LimitExceeded
                } else {
                    ErrorCode::InvalidResult
                },
                e.to_string(),
            )
        })?;
        Ok(writer.bytes)
    }
    fn validate(&self) -> Result<()> {
        match self {
            Self::Recognized { formula } => {
                if formula.latex.trim().is_empty() {
                    return Err(Error::result("recognized LaTeX must not be empty"));
                }
                formula.provenance.validate()
            }
            Self::Truncated { provenance, .. } => provenance.validate(),
            Self::Failed { .. } => Ok(()),
        }
    }
}
/// Recognition state in a progressive page snapshot.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum FormulaState {
    /// Explicit layout-only request.
    NotRequested,
    /// Detected but not yet terminal, including interrupted partial pages.
    Pending,
    /// Exactly one terminal recognition result.
    Finished {
        /// Recognized, failed, or truncated result.
        outcome: FormulaOutcome,
    },
}
/// Formula state associated with an existing layout region.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct FormulaResult {
    /// Stable layout region identity.
    pub region_id: RegionId,
    /// Progressive recognition state.
    pub state: FormulaState,
}
/// Optional model-supported reading order, not inferred from vector enumeration.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReadingOrder {
    /// Ordered permutation of the page's region IDs.
    pub region_ids: Vec<RegionId>,
    /// Model/adapter ordering profile.
    pub profile: ProfileId,
}
/// Owned page snapshot. Results do not retain an image lease.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct PageAnalysis {
    /// Source identity and canonical dimensions.
    pub page: PageDescriptor,
    /// Raster and layout provenance.
    pub provenance: PageProvenance,
    /// Snapshot of requested recognition scope.
    pub formula_scope: FormulaScope,
    /// Stable region enumeration, including valid nested formulas.
    pub regions: Vec<LayoutRegion>,
    /// Exactly one state for each formula region, and none for equation numbers.
    pub formulas: Vec<FormulaResult>,
    /// Optional model-supported reading order.
    pub reading_order: Option<ReadingOrder>,
    /// Nonfatal page observations.
    pub diagnostics: Vec<Diagnostic>,
}
impl PageAnalysis {
    /// Validate and encode a final page using a bounded output allocation.
    pub fn to_json(&self, max_bytes: usize) -> Result<Vec<u8>> {
        self.validate(true)?;
        let mut writer = BoundedWriter {
            bytes: Vec::new(),
            limit: max_bytes,
            exceeded: false,
        };
        serde_json::to_writer(&mut writer, self).map_err(|e| {
            Error::new(
                if writer.exceeded {
                    ErrorCode::LimitExceeded
                } else {
                    ErrorCode::InvalidResult
                },
                e.to_string(),
            )
        })?;
        Ok(writer.bytes)
    }
    /// Validate local consistency; final snapshots cannot contain pending work.
    pub fn validate(&self, final_snapshot: bool) -> Result<()> {
        self.provenance.pipeline.validate()?;
        let image = self.provenance.image;
        self.provenance.pixel_to_page.map_rect(Rect::new(
            0.,
            0.,
            f64::from(image.width()),
            f64::from(image.height()),
        )?)?;
        let mut ids = HashSet::new();
        let mut formulas = BTreeMap::new();
        for region in &self.regions {
            region.validate()?;
            if !ids.insert(region.id) {
                return Err(Error::result("duplicate region ID"));
            }
            if let Some(kind) = region.display_kind {
                formulas.insert(region.id.0, kind);
            }
        }
        let mut seen = HashSet::new();
        for result in &self.formulas {
            let Some(kind) = formulas.get(&result.region_id.0) else {
                return Err(Error::result(
                    "formula result references a non-formula region",
                ));
            };
            if !seen.insert(result.region_id) {
                return Err(Error::result("duplicate formula result"));
            }
            match (&self.formula_scope, &result.state) {
                (FormulaScope::None, FormulaState::NotRequested) => {}
                (FormulaScope::All, FormulaState::Pending) if !final_snapshot => {}
                (FormulaScope::All, FormulaState::Finished { outcome }) => {
                    outcome.validate()?;
                    if matches!(outcome, FormulaOutcome::Recognized { formula } if &formula.display_kind != kind)
                    {
                        return Err(Error::result("recognition changed formula display context"));
                    }
                }
                _ => {
                    return Err(Error::result(
                        "formula state contradicts page scope or finality",
                    ));
                }
            }
        }
        if seen.len() != formulas.len() {
            return Err(Error::result("missing formula states"));
        }
        if let Some(order) = &self.reading_order {
            let ordered: HashSet<_> = order.region_ids.iter().copied().collect();
            if ordered.len() != order.region_ids.len() || ordered != ids {
                return Err(Error::result(
                    "reading order must be a permutation of region IDs",
                ));
            }
        }
        Ok(())
    }
}
/// Processing status; a future job's completion also accounts for delivery.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CompletionStatus {
    /// All requested work completed successfully.
    Completed,
    /// All work was attempted with page/formula failures or truncation.
    Partial,
    /// Cancellation preserved a completed prefix.
    Cancelled,
    /// A fatal backend, source, worker, or delivery failure stopped work.
    Failed,
}
/// Counts without a retained document-sized page/result graph.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct AnalysisCounts {
    /// Number of requested pages.
    pub pages_total: u64,
    /// Pages with final usable layout snapshots, including formula failures.
    pub pages_finished: u64,
    /// Pages unable to produce layout.
    pub pages_failed: u64,
    /// Formula regions detected so far.
    pub formulas_detected: u64,
    /// Successfully recognized expressions.
    pub formulas_recognized: u64,
    /// Failed expressions.
    pub formulas_failed: u64,
    /// Truncated expressions.
    pub formulas_truncated: u64,
    /// Unfinished expressions.
    pub formulas_pending: u64,
    /// Explicitly unrequested recognition.
    pub formulas_not_requested: u64,
}
/// Processing summary; terminal-notice delivery is not implied by this value.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct AnalysisSummary {
    /// Processing status.
    pub status: CompletionStatus,
    /// Document counts.
    pub counts: AnalysisCounts,
    /// Owned diagnostics, including fatal failure context.
    pub diagnostics: Vec<Diagnostic>,
}
impl AnalysisSummary {
    fn validate(&self) -> Result<()> {
        let c = self.counts;
        let pages = c
            .pages_finished
            .checked_add(c.pages_failed)
            .ok_or_else(|| Error::result("page count overflow"))?;
        let formulas = [
            c.formulas_recognized,
            c.formulas_failed,
            c.formulas_truncated,
            c.formulas_pending,
            c.formulas_not_requested,
        ]
        .into_iter()
        .try_fold(0u64, |n, v| n.checked_add(v))
        .ok_or_else(|| Error::result("formula count overflow"))?;
        if pages > c.pages_total || formulas != c.formulas_detected {
            return Err(Error::result("inconsistent summary counts"));
        }
        let failures = c.pages_failed != 0 || c.formulas_failed != 0 || c.formulas_truncated != 0;
        if matches!(
            self.status,
            CompletionStatus::Completed | CompletionStatus::Partial
        ) && (pages != c.pages_total || c.formulas_pending != 0)
        {
            return Err(Error::result("finished summary contains unfinished work"));
        }
        if (self.status == CompletionStatus::Completed && failures)
            || (self.status == CompletionStatus::Partial && !failures)
        {
            return Err(Error::result("summary status contradicts failures"));
        }
        Ok(())
    }
}
/// Semantic updates in source-page and stable-region order.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum UpdatePayload {
    /// Layout has completed; all requested formula states are initially pending.
    PageLayoutReady {
        /// Immutable initial page snapshot.
        page: Box<PageAnalysis>,
    },
    /// One formula reaches a terminal state after its layout was delivered.
    FormulaFinished {
        /// Source page.
        page_key: PageKey,
        /// Existing layout region.
        region_id: RegionId,
        /// Terminal outcome.
        outcome: FormulaOutcome,
    },
    /// Final authoritative page snapshot.
    PageFinished {
        /// Completed page data.
        page: Box<PageAnalysis>,
    },
    /// No usable layout result for this page.
    PageFailed {
        /// Source page.
        page_key: PageKey,
        /// Owned failure.
        error: Error,
    },
    /// Processing ended; future `done` remains authoritative for delivery success.
    DocumentFinished {
        /// Counts and status, without a document raster graph.
        summary: AnalysisSummary,
    },
}
/// Validated update envelope. Sequence ordering across updates is enforced by jobs in M3.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(try_from = "UpdateWire")]
pub struct AnalysisUpdate {
    schema_version: u32,
    analysis_id: AnalysisId,
    document: DocumentRef,
    sequence: u64,
    payload: UpdatePayload,
}
#[derive(Deserialize)]
struct UpdateWire {
    schema_version: u32,
    analysis_id: AnalysisId,
    document: DocumentRef,
    sequence: u64,
    payload: UpdatePayload,
}
impl AnalysisUpdate {
    /// Validate ownership identities and payload invariants without running a model.
    pub fn new(
        analysis_id: AnalysisId,
        document: DocumentRef,
        sequence: u64,
        payload: UpdatePayload,
    ) -> Result<Self> {
        let page_key = match &payload {
            UpdatePayload::PageLayoutReady { page } => {
                page.validate(false)?;
                if page
                    .formulas
                    .iter()
                    .any(|f| matches!(f.state, FormulaState::Finished { .. }))
                {
                    return Err(Error::result(
                        "initial layout contains finished recognition",
                    ));
                }
                Some(&page.page.key)
            }
            UpdatePayload::PageFinished { page } => {
                page.validate(true)?;
                Some(&page.page.key)
            }
            UpdatePayload::FormulaFinished {
                page_key, outcome, ..
            } => {
                outcome.validate()?;
                Some(page_key)
            }
            UpdatePayload::PageFailed { page_key, .. } => Some(page_key),
            UpdatePayload::DocumentFinished { summary } => {
                summary.validate()?;
                None
            }
        };
        if page_key.is_some_and(|key| key.document != document) {
            return Err(Error::result("page and update document revisions differ"));
        }
        Ok(Self {
            schema_version: RESULT_SCHEMA_VERSION,
            analysis_id,
            document,
            sequence,
            payload,
        })
    }
    /// Analysis identity.
    pub fn analysis_id(&self) -> &AnalysisId {
        &self.analysis_id
    }
    /// Immutable document reference.
    pub fn document(&self) -> &DocumentRef {
        &self.document
    }
    /// Per-job monotonic sequence number, not a timestamp.
    pub fn sequence(&self) -> u64 {
        self.sequence
    }
    /// Owned semantic payload.
    pub fn payload(&self) -> &UpdatePayload {
        &self.payload
    }
    /// Encode without allocating a payload larger than the supplied limit.
    pub fn to_json(&self, max_bytes: usize) -> Result<Vec<u8>> {
        let mut writer = BoundedWriter {
            bytes: Vec::new(),
            limit: max_bytes,
            exceeded: false,
        };
        if let Err(error) = serde_json::to_writer(&mut writer, self) {
            return Err(Error::new(
                if writer.exceeded {
                    ErrorCode::LimitExceeded
                } else {
                    ErrorCode::InvalidResult
                },
                error.to_string(),
            ));
        }
        Ok(writer.bytes)
    }
    /// Decode bounded JSON and validate all identities, geometry, and state.
    /// Unknown optional fields are ignored; unknown required variants fail.
    pub fn from_json(bytes: &[u8], max_bytes: usize) -> Result<Self> {
        if bytes.len() > max_bytes {
            return Err(Error::new(
                ErrorCode::LimitExceeded,
                "result payload exceeds byte budget",
            ));
        }
        serde_json::from_slice(bytes).map_err(|e| {
            let message = e.to_string();
            let code = if message.contains("unsupported result schema")
                || message.contains("unknown variant")
            {
                ErrorCode::UnsupportedSchema
            } else {
                ErrorCode::InvalidResult
            };
            Error::new(code, message)
        })
    }
}
impl TryFrom<UpdateWire> for AnalysisUpdate {
    type Error = Error;
    fn try_from(v: UpdateWire) -> Result<Self> {
        if v.schema_version != RESULT_SCHEMA_VERSION {
            return Err(Error::new(
                ErrorCode::UnsupportedSchema,
                "unsupported result schema",
            ));
        }
        Self::new(v.analysis_id, v.document, v.sequence, v.payload)
    }
}
struct BoundedWriter {
    bytes: Vec<u8>,
    limit: usize,
    exceeded: bool,
}
impl Write for BoundedWriter {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        if bytes.len() > self.limit.saturating_sub(self.bytes.len()) {
            self.exceeded = true;
            return Err(std::io::Error::other("result payload exceeds byte budget"));
        }
        let needed = self.bytes.len() + bytes.len();
        if needed > self.bytes.capacity() {
            let capacity = self
                .bytes
                .capacity()
                .saturating_mul(2)
                .max(needed)
                .min(self.limit);
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
