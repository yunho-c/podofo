//! Convert explicit LaTeX expressions to MathML/plain speech, without ML models.
use podoco::{
    math::{MathInput, MathLimits, MathProcessor, MathRules, MathSpeechOptions},
    results::FormulaDisplayKind,
};
use std::io::BufRead;

#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct Case {
    id: String,
    input: MathInput,
    options: MathSpeechOptions,
}
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<_> = std::env::args().skip(1).collect();
    let [rules, language, style, expressions @ ..] = args.as_slice() else {
        return Err("usage: math RULES LANGUAGE SPEECH_STYLE LATEX [LATEX ...]".into());
    };
    if expressions.is_empty() {
        return Err("at least one expression is required".into());
    }
    let processor = MathProcessor::open(MathRules::verify(rules)?, MathLimits::default())?;
    if expressions.len() == 2 && expressions[0] == "--jsonl" {
        for line in std::io::BufReader::new(std::fs::File::open(&expressions[1])?).lines() {
            let case: Case = serde_json::from_str(&line?)?;
            let result = processor.to_speech(case.input, case.options);
            println!(
                "{}",
                match result {
                    Ok(value) => serde_json::json!({"id":case.id,"value":value}),
                    Err(error) => serde_json::json!({"id":case.id,"error":error}),
                }
            );
        }
        processor.close()?;
        return Ok(());
    }
    for expression in expressions {
        let speech = processor.to_speech(
            MathInput::latex(expression, FormulaDisplayKind::Inline),
            MathSpeechOptions::new(language, style),
        );
        match speech {
            Ok(speech) => println!("{}", String::from_utf8(speech.to_json(256 * 1024)?)?),
            Err(error) => println!("{}", serde_json::json!({"error":error})),
        }
    }
    processor.close()?;
    Ok(())
}
