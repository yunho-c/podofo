mod preprocess;
#[cfg(test)]
mod tests;

use crate::{
    Error, ErrorCode, ModelBundle, PageAnalysis, PageInput, ProfileId, Rect, RegionId, Result,
    bundle::LayoutProfile,
    domain::Score,
    options::{ComputePolicy, FormulaScope},
    results::{
        FormulaResult, FormulaState, LayoutRegion, ModelProvenance, PageProvenance,
        PipelineProvenance, ReadingOrder, RegionCategory,
    },
};
use preprocess::{INPUT_LEN, Preprocessor};

pub(crate) const PROFILE: &str = "pp-doclayout-v3-transformers-5.8.1-score030-stable-v1";
const SMALL_LEN: usize = 7500 + 1200 + 90000;
const NATIVE_MIN: u64 = (INPUT_LEN * 4 + SMALL_LEN * 4 + 48_000_000) as u64;
const HOST_BYTES: u64 = ((INPUT_LEN + SMALL_LEN) * 4) as u64 + Preprocessor::BYTES;
const SCRATCH_BYTES: u64 = 128 * 1024;
pub(crate) const MIN_TENSOR_BYTES: u64 = HOST_BYTES + NATIVE_MIN + SCRATCH_BYTES;

fn sigmoid(value: f32) -> f32 {
    1.0 / (1.0 + (-value).exp())
}

// Pinned ATen SumKernel.cpp's four-level reduction. The last twelve columns
// take row_sum's four interleaved lanes; earlier columns use the outer kernel.
fn cascade(size: usize, mut get: impl FnMut(usize) -> f32) -> f32 {
    let mut sums = [0.0f32; 4];
    let mut i = 0;
    while i + 16 <= size {
        for _ in 0..16 {
            sums[0] += get(i);
            i += 1;
        }
        for j in 1..4 {
            sums[j] += sums[j - 1];
            sums[j - 1] = 0.0;
            if (i & (15 << (j * 4))) != 0 {
                break;
            }
        }
    }
    for j in i..size {
        sums[0] += get(j);
    }
    for j in 1..4 {
        sums[0] += sums[j];
    }
    sums[0]
}
fn vote_sum(query: usize, get: impl Fn(usize) -> f32) -> f32 {
    if query < 288 {
        cascade(300, get)
    } else {
        let mut lanes = [0.0f32; 4];
        for (lane, sum) in lanes.iter_mut().enumerate() {
            *sum = cascade(75, |i| get(i * 4 + lane));
        }
        ((lanes[0] + lanes[1]) + lanes[2]) + lanes[3]
    }
}

fn decode(
    profile: &LayoutProfile,
    input: &PageInput,
    provenance: &PipelineProvenance,
    logits: &[f32],
    boxes: &[f32],
    order: &[f32],
) -> Result<PageAnalysis> {
    if logits.len() != 7500
        || boxes.len() != 1200
        || order.len() != 90000
        || logits
            .iter()
            .chain(boxes)
            .chain(order)
            .any(|v| !v.is_finite())
    {
        return Err(Error::new(
            ErrorCode::Layout,
            "invalid or non-finite layout output",
        ));
    }
    let mut candidates: Vec<_> = logits
        .iter()
        .enumerate()
        .map(|(i, &v)| (i, sigmoid(v)))
        .collect();
    candidates.sort_unstable_by(|(i, a), (j, b)| b.total_cmp(a).then_with(|| i.cmp(j)));
    candidates.truncate(300);
    candidates.retain(|&(_, score)| score >= 0.30);
    let mut votes = [0.0f32; 300];
    for (q, vote) in votes.iter_mut().enumerate() {
        let above = vote_sum(q, |r| {
            if r < q {
                sigmoid(order[r * 300 + q])
            } else {
                0.0
            }
        });
        let below = vote_sum(q, |r| {
            if r > q {
                1.0 - sigmoid(order[q * 300 + r])
            } else {
                0.0
            }
        });
        *vote = above + below;
    }
    candidates.sort_unstable_by(|(a, _), (b, _)| {
        votes[a / 25]
            .total_cmp(&votes[b / 25])
            .then_with(|| (a / 25).cmp(&(b / 25)))
            .then_with(|| (a % 25).cmp(&(b % 25)))
    });
    let mut regions = Vec::with_capacity(candidates.len());
    let width = input.image().descriptor().width() as f32;
    let height = input.image().descriptor().height() as f32;
    for (flat, score) in candidates {
        let class = &profile.classes[flat % 25];
        let b = &boxes[(flat / 25) * 4..][..4];
        let bounds = Rect::new(
            f64::from((b[0] - 0.5 * b[2]) * width),
            f64::from((b[1] - 0.5 * b[3]) * height),
            f64::from((b[0] + 0.5 * b[2]) * width),
            f64::from((b[1] + 0.5 * b[3]) * height),
        )
        .and_then(|r| input.pixel_to_page().map_rect(r))
        .map_err(|e| Error::new(ErrorCode::Layout, e.message))?;
        regions.push(LayoutRegion {
            id: RegionId(flat as u32),
            category: class.category,
            model_class_id: class.id,
            model_label: class.label.clone(),
            native_subtype: Some(class.native_subtype.clone()),
            display_kind: class.display_kind,
            bounds,
            polygon: None,
            score: Some(Score::new(f64::from(score))?),
            diagnostics: Vec::new(),
        });
    }
    let formulas = regions
        .iter()
        .filter(|r| r.category == RegionCategory::Formula)
        .map(|r| FormulaResult {
            region_id: r.id,
            state: FormulaState::NotRequested,
        })
        .collect();
    let reading_order = Some(ReadingOrder {
        region_ids: regions.iter().map(|r| r.id).collect(),
        profile: ProfileId::new(&profile.postprocessing.reading_order)?,
    });
    let page = PageAnalysis {
        page: input.descriptor().clone(),
        provenance: PageProvenance {
            pipeline: provenance.clone(),
            render_profile: input.render_profile().clone(),
            image: input.image().descriptor(),
            pixel_to_page: input.pixel_to_page(),
        },
        formula_scope: FormulaScope::None,
        regions,
        formulas,
        reading_order,
        diagnostics: Vec::new(),
    };
    page.validate(true)?;
    Ok(page)
}

fn provenance(bundle: &ModelBundle, policy: ComputePolicy) -> Result<PipelineProvenance> {
    let manifest = bundle.manifest();
    Ok(PipelineProvenance {
        sdk_version: ProfileId::new(crate::VERSION)?,
        backend: ProfileId::new("coreml")?,
        compute_policy: policy,
        adapter: ProfileId::new(&manifest.profile.adapter)?,
        profile: ProfileId::new(&manifest.profile.id)?,
        models: vec![ModelProvenance {
            model_id: ProfileId::new(&manifest.id)?,
            manifest_sha256: bundle.manifest_sha256().clone(),
            artifacts: manifest
                .artifacts
                .values()
                .flat_map(|a| {
                    a.files
                        .iter()
                        .map(|f| (format!("{}/{}", a.path, f.path), f.sha256.clone()))
                })
                .collect(),
        }],
    })
}

#[cfg(feature = "coreml")]
pub(crate) struct Pipeline {
    native: crate::runtime::coreml::LayoutModel,
    pub(crate) failed: bool,
    preprocessor: Preprocessor,
    input: Vec<f32>,
    logits: Vec<f32>,
    boxes: Vec<f32>,
    order: Vec<f32>,
    profile: LayoutProfile,
    provenance: PipelineProvenance,
}
#[cfg(feature = "coreml")]
impl Pipeline {
    pub(crate) fn initial_stats(&self) -> crate::LayoutSessionStats {
        crate::LayoutSessionStats {
            model_loads: 1,
            host_buffer_bytes: HOST_BYTES,
            peak_tensor_bytes: HOST_BYTES + self.native.input_span() + SCRATCH_BYTES,
            ..Default::default()
        }
    }
    pub(crate) fn open(bundle: &ModelBundle, options: &crate::AnalyzerOptions) -> Result<Self> {
        if options.limits.tensor_bytes() < MIN_TENSOR_BYTES {
            return Err(Error::new(
                ErrorCode::LimitExceeded,
                format!("layout tensors require at least {MIN_TENSOR_BYTES} bytes"),
            ));
        }
        let native = crate::runtime::coreml::LayoutModel::load(
            bundle,
            options.compute_policy,
            options.limits.tensor_bytes() - HOST_BYTES - SCRATCH_BYTES,
        )?;
        fn buffer(len: usize) -> Result<Vec<f32>> {
            let mut v = Vec::new();
            v.try_reserve_exact(len)
                .map_err(|e| Error::new(ErrorCode::LimitExceeded, e.to_string()))?;
            v.resize(len, 0.0);
            Ok(v)
        }
        Ok(Self {
            native,
            failed: false,
            preprocessor: Preprocessor::new(),
            input: buffer(INPUT_LEN)?,
            logits: buffer(7500)?,
            boxes: buffer(1200)?,
            order: buffer(90000)?,
            profile: bundle.manifest().profile.clone(),
            provenance: provenance(bundle, options.compute_policy)?,
        })
    }
    pub(crate) fn analyze(
        &mut self,
        input: &PageInput,
        stats: &mut crate::LayoutSessionStats,
    ) -> Result<PageAnalysis> {
        use std::time::Instant;
        let start = Instant::now();
        self.preprocessor.run(input.image(), &mut self.input)?;
        stats.last_timings.preprocessing_seconds = start.elapsed().as_secs_f64();
        let start = Instant::now();
        stats.predictions += 1;
        let bytes = self
            .native
            .predict(
                &self.input,
                &mut self.logits,
                &mut self.boxes,
                &mut self.order,
            )
            .inspect_err(|_| self.failed = true)?;
        stats.last_timings.prediction_seconds = start.elapsed().as_secs_f64();
        stats.peak_tensor_bytes = stats
            .peak_tensor_bytes
            .max(bytes + HOST_BYTES + SCRATCH_BYTES);
        stats.host_buffer_bytes = HOST_BYTES;
        let start = Instant::now();
        let page = decode(
            &self.profile,
            input,
            &self.provenance,
            &self.logits,
            &self.boxes,
            &self.order,
        );
        stats.last_timings.decoding_seconds = start.elapsed().as_secs_f64();
        page
    }
}
