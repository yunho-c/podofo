//! Explicit single-crop recognition, preserving full native qualification data.
#[path = "support/png_input.rs"]
mod png_input;
use podoco::{
    AnalyzerOptions, Rect, RegionId, ResourceLimits,
    formula::{FormulaBundle, FormulaCancellation, FormulaInput, FormulaOptions, FormulaSession},
    options::ComputePolicy,
    results::FormulaDisplayKind,
};
use std::{error::Error, io::Write, path::Path};
fn main() -> Result<(), Box<dyn Error>> {
    let args: Vec<_> = std::env::args().skip(1).collect();
    let [bundle, policy, cap, paths @ ..] = args.as_slice() else {
        return Err("usage: formula BUNDLE cpu|cpu-ne|all TOKEN_CAP CROP.png ...".into());
    };
    if paths.is_empty() {
        return Err("at least one crop is required".into());
    }
    let policy = match policy.as_str() {
        "cpu" => ComputePolicy::CpuOnly,
        "cpu-ne" => ComputePolicy::CpuAndNeuralEngine,
        "all" => ComputePolicy::All,
        _ => return Err("invalid compute policy".into()),
    };
    let options = FormulaOptions::new(cap.parse()?)?;
    let mut session = FormulaSession::open(
        FormulaBundle::verify(bundle)?,
        AnalyzerOptions {
            compute_policy: policy,
            limits: ResourceLimits::new(
                1,
                64 * 1024 * 1024,
                1,
                2 * 1024 * 1024,
                2 * 1024 * 1024,
                128 * 1024 * 1024,
                48 * 1024 * 1024,
            )?,
        },
    )?;
    let stdout = std::io::stdout();
    let mut out = stdout.lock();
    for (i, path) in paths.iter().enumerate() {
        let page = png_input::page(Path::new(path), i.try_into()?, 64 * 1024 * 1024)?;
        let d = page.image().descriptor();
        let bounds = Rect::new(0., 0., f64::from(d.width()), f64::from(d.height()))?;
        let outcome = session.recognize(
            FormulaInput {
                page,
                region_id: RegionId(0),
                bounds,
                display_kind: FormulaDisplayKind::Unknown,
            },
            options,
            FormulaCancellation::default(),
        )?;
        serde_json::to_writer(
            &mut out,
            &serde_json::json!({"input":path,"outcome":outcome,"stats":session.stats()}),
        )?;
        writeln!(out)?;
        out.flush()?;
    }
    session.close()?;
    Ok(())
}
