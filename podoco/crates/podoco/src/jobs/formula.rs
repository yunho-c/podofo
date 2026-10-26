//! Compose the qualified sessions behind the existing bounded document lane.
use super::engine::Pipeline;
use crate::{
    AnalysisOptions, AnalyzerOptions, Capabilities, Error, ErrorCode, FormulaOutcome, FormulaScope,
    LayoutRegion, LayoutSession, ModelBundle, PageAnalysis, PageInput, ProfileId, ResourceLimits,
    Result,
    formula::{FormulaBundle, FormulaInput, FormulaOptions, FormulaSession},
    results::ModelProvenance,
};

struct FormulaPipeline {
    layout: LayoutSession,
    formula: FormulaSession,
    options: FormulaOptions,
    layout_profile: ProfileId,
    profile: ProfileId,
    model: ModelProvenance,
}
pub(super) fn open(
    layout: ModelBundle,
    formula: FormulaBundle,
    options: AnalyzerOptions,
    formula_options: FormulaOptions,
) -> Result<(Box<dyn Pipeline>, String)> {
    // Inactive sessions retain their input/host buffers while the other runs.
    // Reserve 32 MiB for the other session; model weights/workspaces are opaque.
    let tensor = options
        .limits
        .tensor_bytes()
        .checked_sub(32 * 1024 * 1024)
        .filter(|remaining| *remaining >= 64 * 1024 * 1024)
        .ok_or_else(|| {
            Error::new(
                ErrorCode::LimitExceeded,
                "combined pipeline needs at least 96 MiB tensor bytes",
            )
        })?;
    let l = options.limits;
    let session_options = AnalyzerOptions {
        compute_policy: options.compute_policy,
        limits: ResourceLimits::new(
            l.queued_jobs(),
            l.input_bytes(),
            l.pending_updates(),
            l.result_bytes(),
            l.max_update_bytes(),
            tensor,
            l.decoder_cache_bytes(),
        )?,
    };
    let layout_profile = ProfileId::new(&layout.manifest().profile.id)?;
    let mut profile = "pp-doclayout-v3-formulanet-plus-l-greedy2048-v1".to_string();
    if formula_options.max_new_tokens() != 2048 {
        profile.push_str(&format!("-cap{}", formula_options.max_new_tokens()));
    }
    let model = ModelProvenance {
        model_id: ProfileId::new(&formula.manifest().id)?,
        manifest_sha256: formula.manifest_sha256().clone(),
        artifacts: formula
            .manifest()
            .files
            .iter()
            .map(|f| (f.path.clone(), f.sha256.clone()))
            .collect(),
    };
    let layout = LayoutSession::open(layout, session_options.clone())?;
    let formula = FormulaSession::open(formula, session_options)?;
    Ok((
        Box::new(FormulaPipeline {
            layout,
            formula,
            options: formula_options,
            layout_profile,
            profile: ProfileId::new(&profile)?,
            model,
        }),
        profile,
    ))
}
impl Pipeline for FormulaPipeline {
    fn capabilities(&self) -> Capabilities {
        Capabilities {
            formula_recognition: true,
            ..self.layout.capabilities()
        }
    }
    fn layout(&mut self, input: &PageInput, options: &AnalysisOptions) -> Result<PageAnalysis> {
        let mut layout_options = options.clone();
        layout_options.profile = self.layout_profile.clone();
        layout_options.formula_scope = FormulaScope::None;
        let mut page = self.layout.analyze_page(input.clone(), layout_options)?;
        page.provenance.pipeline.profile = self.profile.clone();
        page.provenance.pipeline.adapter = ProfileId::new("pp-doclayout-v3-formulanet-plus-l-v1")?;
        page.provenance.pipeline.models.push(self.model.clone());
        Ok(page)
    }
    fn recognize(
        &mut self,
        input: &PageInput,
        region: &LayoutRegion,
        cancel: &super::CancellationHandle,
    ) -> Result<FormulaOutcome> {
        let cancel = cancel.clone();
        self.formula.recognize_with_cancel(
            FormulaInput {
                page: input.clone(),
                region_id: region.id,
                bounds: region.bounds,
                display_kind: region
                    .display_kind
                    .ok_or_else(|| Error::input("recognition requires formula context"))?,
            },
            self.options,
            Box::new(move || cancel.is_cancelled()),
        )
    }
    fn failed(&self) -> bool {
        self.layout.failed() || self.formula.failed()
    }
}
