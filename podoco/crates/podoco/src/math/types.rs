use crate::{
    Error, ErrorCode, ProfileId, Result,
    domain::Sha256Digest,
    results::{Diagnostic, FormulaDisplayKind},
};
use serde::{Deserialize, Serialize};

/// Source syntax; conversion never replaces the caller's recognized LaTeX.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MathFormat {
    /// A single mathematical expression, optionally enclosed in one math fence.
    Latex,
    /// One presentation MathML `math` element.
    Mathml,
}
/// Owned expression and explicit detector/caller display context.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MathInput {
    /// Input syntax.
    pub format: MathFormat,
    /// Exact source expression.
    pub text: String,
    /// Unknown uses inline conversion semantics with a diagnostic.
    pub display_kind: FormulaDisplayKind,
}
impl MathInput {
    /// Convert a LaTeX expression without modifying its source.
    pub fn latex(text: impl Into<String>, display_kind: FormulaDisplayKind) -> Self {
        Self {
            format: MathFormat::Latex,
            text: text.into(),
            display_kind,
        }
    }
    /// Convert caller-supplied presentation MathML.
    pub fn mathml(text: impl Into<String>, display_kind: FormulaDisplayKind) -> Self {
        Self {
            format: MathFormat::Mathml,
            text: text.into(),
            display_kind,
        }
    }
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Limits {
    queued_requests: u32,
    input_bytes: u32,
    output_bytes: u32,
    nodes: u32,
    depth: u32,
}
/// Bounded admission, source/output size and parser complexity. Rule tables,
/// dependency internals and worker stacks are outside these logical limits.
#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
#[serde(try_from = "Limits", into = "Limits")]
pub struct MathLimits(Limits);
impl MathLimits {
    /// Validate positive limits, capped at 32 queued requests, 64 KiB input,
    /// 1 MiB output, 8192 syntax/XML nodes and 64 levels of nesting.
    pub fn new(
        queued_requests: u32,
        input_bytes: u32,
        output_bytes: u32,
        nodes: u32,
        depth: u32,
    ) -> Result<Self> {
        Limits {
            queued_requests,
            input_bytes,
            output_bytes,
            nodes,
            depth,
        }
        .try_into()
    }
    /// Maximum queued requests, excluding one active conversion.
    pub fn queued_requests(self) -> u32 {
        self.0.queued_requests
    }
    /// Maximum UTF-8 source length.
    pub fn input_bytes(self) -> u32 {
        self.0.input_bytes
    }
    /// Maximum MathML/speech serialization and derived string length.
    pub fn output_bytes(self) -> u32 {
        self.0.output_bytes
    }
    /// Maximum LaTeX parser events and XML nodes.
    pub fn nodes(self) -> u32 {
        self.0.nodes
    }
    /// Maximum brace/group and XML nesting.
    pub fn depth(self) -> u32 {
        self.0.depth
    }
}
impl Default for MathLimits {
    fn default() -> Self {
        Self::new(4, 64 * 1024, 256 * 1024, 8192, 64).expect("constant math limits")
    }
}
impl TryFrom<Limits> for MathLimits {
    type Error = Error;
    fn try_from(v: Limits) -> Result<Self> {
        if !(1..=32).contains(&v.queued_requests)
            || !(1..=65536).contains(&v.input_bytes)
            || !(1..=1_048_576).contains(&v.output_bytes)
            || !(1..=8192).contains(&v.nodes)
            || !(1..=64).contains(&v.depth)
        {
            return Err(Error::input(
                "math limits exceed supported bounds or contain zero",
            ));
        }
        Ok(Self(v))
    }
}
impl From<MathLimits> for Limits {
    fn from(v: MathLimits) -> Self {
        v.0
    }
}

/// Supported MathCAT verbosity.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum MathVerbosity {
    /// Compact mathematical speech.
    Terse,
    /// Default balance of structural cues and brevity.
    Medium,
    /// More explicit structural cues.
    Verbose,
}
/// Complete public preference snapshot, applied atomically with each expression.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MathSpeechOptions {
    /// Exact installed language ID; automatic/fallback language is unsupported.
    pub language: String,
    /// Exact installed style such as `ClearSpeak` or `SimpleSpeak`.
    pub speech_style: String,
    /// Amount of structural detail.
    pub verbosity: MathVerbosity,
    /// Characters interpreted as decimal separators, independent of speech language.
    pub decimal_separators: String,
    /// Characters interpreted as digit-group separators.
    pub block_separators: String,
}
impl MathSpeechOptions {
    /// Select explicit language/style with medium verbosity and profile numeric
    /// defaults: dot decimal and comma/space/nonbreaking-space digit grouping.
    pub fn new(language: impl Into<String>, speech_style: impl Into<String>) -> Self {
        Self {
            language: language.into(),
            speech_style: speech_style.into(),
            verbosity: MathVerbosity::Medium,
            decimal_separators: ".".into(),
            block_separators: ", \u{00a0}\u{202f}".into(),
        }
    }
    pub(super) fn validate(&self) -> Result<()> {
        if self.language.is_empty()
            || self.language.len() > 64
            || self.speech_style.is_empty()
            || self.speech_style.len() > 64
            || self.decimal_separators.is_empty()
            || self.decimal_separators.chars().count() > 8
            || self.block_separators.chars().count() > 8
            || self
                .decimal_separators
                .chars()
                .any(|c| c.is_control() || c.is_whitespace() || self.block_separators.contains(c))
            || self.block_separators.chars().any(char::is_control)
        {
            return Err(Error::input(
                "invalid math language/style or numeric separator snapshot",
            ));
        }
        Ok(())
    }
}
/// A language/style combination present in the verified rule set. Availability
/// is not a claim that every language has undergone human listening review.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct MathLanguage {
    /// Exact language ID.
    pub language: String,
    /// Exact supported styles.
    pub speech_styles: Vec<String>,
}
/// Versioned dependencies and rules used for derived math/speech output.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct MathProvenance {
    /// Podoco package version.
    pub sdk_version: ProfileId,
    /// Converter/MathCAT preference integration profile.
    pub profile: ProfileId,
    /// LaTeX converter, or the direct MathML validation profile.
    pub converter: ProfileId,
    /// MathCAT version including the host-isolation patch.
    pub mathcat: ProfileId,
    /// Exact verified rule manifest.
    pub rules_manifest_sha256: Sha256Digest,
}
/// Owned derived MathML. The source LaTeX remains independently usable.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct MathConversion {
    /// Validated presentation MathML with no external resources.
    pub mathml: String,
    /// Effective display semantics; unknown inputs select inline with a diagnostic.
    pub display_kind: FormulaDisplayKind,
    /// Explicit conversion/default observations.
    pub diagnostics: Vec<Diagnostic>,
    /// Exact conversion dependencies and rules.
    pub provenance: MathProvenance,
}
/// Plain mathematical speech text; this does not synthesize or play audio.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct MathSpeech {
    /// Derived MathML, effective display and provenance.
    #[serde(flatten)]
    pub conversion: MathConversion,
    /// Plain text for an independently configured TTS library.
    pub text: String,
    /// Effective complete public preference snapshot.
    pub options: MathSpeechOptions,
}
pub(super) fn limit(message: &str) -> Error {
    Error::new(ErrorCode::LimitExceeded, message)
}
pub(super) fn conversion(message: impl ToString) -> Error {
    Error::new(
        ErrorCode::Conversion,
        message.to_string().chars().take(2048).collect::<String>(),
    )
}
