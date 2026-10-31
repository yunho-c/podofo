//! Blocking single-page API; PNG decoding belongs to the caller.
#[path = "support/png_input.rs"]
mod png_input;
use png_input::page;
use podoco::{
    AnalysisOptions, AnalyzerOptions, FormulaScope, LayoutSession, ModelBundle, ProfileId,
    ResourceLimits, options::ComputePolicy,
};
use std::{error::Error, io::Write, path::Path};

fn main() -> Result<(), Box<dyn Error>> {
    let args: Vec<_> = std::env::args().skip(1).collect();
    let [
        bundle,
        policy,
        input_bytes,
        tensor_bytes,
        result_bytes,
        pages @ ..,
    ] = args.as_slice()
    else {
        return Err("usage: page_layout BUNDLE cpu|cpu-ne|all INPUT_BYTES TENSOR_BYTES RESULT_BYTES PAGE.png [PAGE.png ...]".into());
    };
    if pages.is_empty() {
        return Err("at least one PNG page is required".into());
    }
    let policy = match policy.as_str() {
        "cpu" => ComputePolicy::CpuOnly,
        "cpu-ne" => ComputePolicy::CpuAndNeuralEngine,
        "all" => ComputePolicy::All,
        _ => return Err("compute policy must be cpu, cpu-ne, or all".into()),
    };
    let input_bytes: u64 = input_bytes.parse()?;
    let result_bytes: u64 = result_bytes.parse()?;
    let start = std::time::Instant::now();
    let bundle = ModelBundle::verify(bundle)?;
    let verification_seconds = start.elapsed().as_secs_f64();
    let mut options = AnalysisOptions::new(ProfileId::new(&bundle.manifest().profile.id)?);
    options.formula_scope = FormulaScope::None;
    let mut session = LayoutSession::open(
        bundle,
        AnalyzerOptions {
            compute_policy: policy,
            limits: ResourceLimits::new(
                1,
                input_bytes,
                1,
                result_bytes,
                result_bytes,
                tensor_bytes.parse()?,
                1,
            )?,
        },
    )?;
    let stdout = std::io::stdout();
    let mut stdout = stdout.lock();
    let mut measurements = Vec::new();
    for (index, path) in pages.iter().enumerate() {
        let result = session.analyze_page(
            page(Path::new(path), u32::try_from(index)?, input_bytes)?,
            options.clone(),
        )?;
        stdout.write_all(&result.to_json(usize::try_from(result_bytes)?)?)?;
        stdout.write_all(b"\n")?;
        measurements.push(session.stats());
    }
    session.close()?;
    eprintln!(
        "{}",
        serde_json::to_string(
            &serde_json::json!({"verification_seconds":verification_seconds,"pages":measurements})
        )?
    );
    Ok(())
}
