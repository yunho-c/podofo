//! Optional, model-independent LaTeX/MathML conversion and mathematical speech.
mod convert;
mod rules;
#[cfg(test)]
mod tests;
mod types;
mod worker;
pub use rules::MathRules;
pub use types::{
    MathConversion, MathFormat, MathInput, MathLanguage, MathLimits, MathProvenance, MathSpeech,
    MathSpeechOptions, MathVerbosity,
};
pub use worker::MathProcessor;
