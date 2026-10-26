//! Eager document jobs with lazy PNG input and a required serial JSONL sink.
#[path = "support/png_input.rs"]
mod png_input;

use podoco::{
    AnalysisOptions, Analyzer, AnalyzerOptions, DocumentRef, Error, ErrorCode, FormulaScope,
    ModelBundle, PageDescriptor, PageInput, PageKey, PageRequest, PageSource, PageSpace, ProfileId,
    ResourceLimits, Result, options::ComputePolicy, results::CompletionStatus,
};
use std::{
    fs::File,
    io::{BufReader, Write},
    path::PathBuf,
};

struct PngPages {
    document: DocumentRef,
    pages: Vec<PageDescriptor>,
    paths: Vec<PathBuf>,
}
impl PngPages {
    fn open(
        paths: &[String],
        input_limit: u64,
    ) -> std::result::Result<Self, Box<dyn std::error::Error>> {
        let document = DocumentRef::new("png-sequence", "1")?;
        let mut pages = Vec::new();
        for (index, path) in paths.iter().enumerate() {
            // Header inspection only; raster decoding happens after admission.
            let mut decoder = png::Decoder::new(BufReader::new(File::open(path)?));
            decoder.set_limits(png::Limits {
                bytes: usize::try_from(input_limit)?,
            });
            let reader = decoder.read_info()?;
            pages.push(PageDescriptor {
                key: PageKey {
                    document: document.clone(),
                    page_index: u32::try_from(index)?,
                },
                space: PageSpace::new(
                    f64::from(reader.info().width),
                    f64::from(reader.info().height),
                )?,
            });
        }
        Ok(Self {
            document,
            pages,
            paths: paths.iter().map(PathBuf::from).collect(),
        })
    }
}
impl PageSource for PngPages {
    fn document(&self) -> &DocumentRef {
        &self.document
    }
    fn pages(&self) -> &[PageDescriptor] {
        &self.pages
    }
    fn load_page(&mut self, request: PageRequest) -> Result<PageInput> {
        if request.cancellation.is_cancelled() {
            return Err(Error::new(ErrorCode::Cancelled, "render cancelled"));
        }
        png_input::page(
            &self.paths[request.page.key.page_index as usize],
            request.page.key.page_index,
            request.byte_budget,
        )
        .map_err(|e| Error::new(ErrorCode::PageSource, e.to_string()))
    }
}

fn main() -> std::result::Result<(), Box<dyn std::error::Error>> {
    let mut args: Vec<_> = std::env::args().skip(1).collect();
    let formula = if args.first().is_some_and(|v| v == "--formula") {
        if args.len() < 4 {
            return Err("--formula needs BUNDLE TOKEN_CAP CACHE_BYTES".into());
        }
        let bundle = podoco::formula::FormulaBundle::verify(&args[1])?;
        let options = podoco::formula::FormulaOptions::new(args[2].parse()?)?;
        let cache = args[3].parse::<u64>()?;
        args.drain(..4);
        Some((bundle, options, cache))
    } else {
        None
    };
    let [
        bundle,
        policy,
        input_bytes,
        tensor_bytes,
        result_bytes,
        max_update_bytes,
        pending_updates,
        pages @ ..,
    ] = args.as_slice()
    else {
        return Err("usage: document_layout BUNDLE cpu|cpu-ne|all INPUT_BYTES TENSOR_BYTES RESULT_BYTES MAX_UPDATE_BYTES PENDING_UPDATES PAGE.png [PAGE.png ...]".into());
    };
    if pages.is_empty() {
        return Err("at least one PNG page is required".into());
    }
    let compute_policy = match policy.as_str() {
        "cpu" => ComputePolicy::CpuOnly,
        "cpu-ne" => ComputePolicy::CpuAndNeuralEngine,
        "all" => ComputePolicy::All,
        _ => return Err("compute policy must be cpu, cpu-ne, or all".into()),
    };
    let input_bytes = input_bytes.parse()?;
    let max_update_bytes: u64 = max_update_bytes.parse()?;
    let source = PngPages::open(pages, input_bytes)?;
    let bundle = ModelBundle::verify(bundle)?;
    let analyzer_options = AnalyzerOptions {
        compute_policy,
        limits: ResourceLimits::new(
            1,
            input_bytes,
            pending_updates.parse()?,
            result_bytes.parse()?,
            max_update_bytes,
            tensor_bytes.parse()?,
            formula.as_ref().map_or(1, |(_, _, cache)| *cache),
        )?,
    };
    let all = formula.is_some();
    let analyzer = match formula {
        Some((formula, options, _)) => {
            Analyzer::open_with_formula(bundle, formula, analyzer_options, options)?
        }
        None => Analyzer::open(bundle, analyzer_options)?,
    };
    let mut options = AnalysisOptions::new(ProfileId::new(analyzer.profile())?);
    options.formula_scope = if all {
        FormulaScope::All
    } else {
        FormulaScope::None
    };
    let job = analyzer.analyze_document(source, options, move |update| {
        let bytes = update.to_json(max_update_bytes.min(usize::MAX as u64) as usize)?;
        let stdout = std::io::stdout();
        let mut output = stdout.lock();
        output
            .write_all(&bytes)
            .and_then(|()| output.write_all(b"\n"))
            .and_then(|()| output.flush())
            .map_err(|e| Error::new(ErrorCode::Delivery, e.to_string()))
    })?;
    // Delivery starts eagerly. Progress observation is optional.
    let outcome = job.wait()?;
    job.close()?;
    analyzer.close()?;
    eprintln!("{}", serde_json::to_string(&outcome)?);
    if outcome.status != CompletionStatus::Completed {
        return Err("document did not complete successfully; see outcome and updates".into());
    }
    Ok(())
}
