use super::{
    types::{conversion, limit},
    *,
};
use crate::{
    Error, ProfileId, Result,
    results::{Diagnostic, FormulaDisplayKind},
};
use std::io::Write;

pub(super) struct Bounded {
    bytes: Vec<u8>,
    limit: usize,
    exceeded: bool,
}
impl Bounded {
    pub(super) fn new(limit: usize) -> Self {
        Self {
            bytes: Vec::new(),
            limit,
            exceeded: false,
        }
    }
    pub(super) fn finish(self) -> Result<Vec<u8>> {
        if self.exceeded {
            Err(limit("math output exceeds byte limit"))
        } else {
            Ok(self.bytes)
        }
    }
}
impl Write for Bounded {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        if bytes.len() > self.limit.saturating_sub(self.bytes.len()) {
            self.exceeded = true;
            return Err(std::io::Error::other("math output exceeds byte limit"));
        }
        self.bytes.extend_from_slice(bytes);
        Ok(bytes.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}
pub(super) fn bounded_json(value: &impl serde::Serialize, max: usize) -> Result<Vec<u8>> {
    let mut out = Bounded::new(max);
    if let Err(e) = serde_json::to_writer(&mut out, value) {
        return Err(if out.exceeded {
            limit("math result serialization exceeds byte limit")
        } else {
            conversion(e)
        });
    }
    out.finish()
}
impl MathConversion {
    /// Encode a bounded owned result. No source/native object is retained.
    pub fn to_json(&self, max_bytes: usize) -> Result<Vec<u8>> {
        bounded_json(self, max_bytes)
    }
}
impl MathSpeech {
    /// Encode a bounded owned speech/conversion result.
    pub fn to_json(&self, max_bytes: usize) -> Result<Vec<u8>> {
        bounded_json(self, max_bytes)
    }
}
pub(super) fn source(input: &MathInput, limits: MathLimits) -> Result<()> {
    if input.text.len() > limits.input_bytes() as usize {
        return Err(limit("math input exceeds byte limit"));
    }
    if input.text.trim().is_empty() || input.text.contains('\0') {
        return Err(Error::input("math input is empty or contains NUL"));
    }
    Ok(())
}
fn diagnostic(code: &str, message: &str) -> Result<Diagnostic> {
    Ok(Diagnostic {
        code: ProfileId::new(code)?,
        message: message.into(),
    })
}
fn preflight(latex: &str, limits: MathLimits) -> Result<()> {
    let mut chars = latex.chars().peekable();
    let (mut depth, mut commands) = (0u32, 0u32);
    while let Some(c) = chars.next() {
        match c {
            '\\' => {
                commands += 1;
                if commands > 256 {
                    return Err(limit("math profile permits at most 256 control sequences"));
                }
                let mut command = String::new();
                while chars.peek().is_some_and(char::is_ascii_alphabetic) {
                    command.push(chars.next().expect("peeked character"));
                }
                if command.is_empty() {
                    chars.next();
                }
                if matches!(
                    command.as_str(),
                    "def"
                        | "gdef"
                        | "edef"
                        | "xdef"
                        | "let"
                        | "futurelet"
                        | "newcommand"
                        | "renewcommand"
                        | "providecommand"
                        | "csname"
                        | "expandafter"
                ) {
                    return Err(conversion(
                        "user-defined macros and expansion directives are unsupported",
                    ));
                }
            }
            '%' => {
                for c in chars.by_ref() {
                    if c == '\n' {
                        break;
                    }
                }
            }
            '{' => {
                depth += 1;
                if depth > limits.depth() {
                    return Err(limit("LaTeX nesting exceeds depth limit"));
                }
            }
            '}' => {
                depth = depth
                    .checked_sub(1)
                    .ok_or_else(|| conversion("unbalanced LaTeX braces"))?;
            }
            _ => {}
        }
    }
    if depth != 0 {
        return Err(conversion("unbalanced LaTeX braces"));
    }
    Ok(())
}
fn xml(text: &str, limits: MathLimits, display: FormulaDisplayKind) -> Result<()> {
    if text.len() > limits.output_bytes() as usize {
        return Err(limit("MathML exceeds output byte limit"));
    }
    if text.contains("<!DOCTYPE") {
        return Err(conversion("MathML document types are unsupported"));
    }
    let document = roxmltree::Document::parse_with_options(
        text,
        roxmltree::ParsingOptions {
            allow_dtd: false,
            nodes_limit: limits.nodes(),
            entity_resolver: None,
        },
    )
    .map_err(|e| {
        if matches!(e, roxmltree::Error::NodesLimitReached) {
            limit("MathML exceeds node limit")
        } else {
            conversion(e)
        }
    })?;
    let root = document.root_element();
    if root.tag_name().name() != "math" {
        return Err(conversion("MathML needs one math root element"));
    }
    let declared = match root.attribute("display") {
        None | Some("inline") => FormulaDisplayKind::Inline,
        Some("block") => FormulaDisplayKind::Displayed,
        _ => return Err(conversion("unsupported MathML display attribute")),
    };
    if declared != display {
        return Err(Error::input(
            "MathML display attribute disagrees with effective display context",
        ));
    }
    for node in document.descendants() {
        if node.is_pi() {
            return Err(conversion("MathML processing instructions are unsupported"));
        }
        if !node.is_element() {
            continue;
        }
        if node.ancestors().filter(|n| n.is_element()).count() > limits.depth() as usize {
            return Err(limit("MathML nesting exceeds depth limit"));
        }
        if node
            .tag_name()
            .namespace()
            .is_some_and(|ns| ns != "http://www.w3.org/1998/Math/MathML")
        {
            return Err(conversion("foreign XML namespaces are unsupported"));
        }
        if !matches!(
            node.tag_name().name(),
            "math"
                | "mrow"
                | "mi"
                | "mn"
                | "mo"
                | "mtext"
                | "ms"
                | "mspace"
                | "mfrac"
                | "msqrt"
                | "mroot"
                | "msub"
                | "msup"
                | "msubsup"
                | "munder"
                | "mover"
                | "munderover"
                | "mtable"
                | "mtr"
                | "mtd"
                | "mlabeledtr"
                | "menclose"
                | "mpadded"
                | "mphantom"
                | "mstyle"
                | "mmultiscripts"
                | "mprescripts"
                | "none"
                | "semantics"
                | "annotation"
        ) {
            return Err(conversion(format!(
                "unsupported MathML element {}",
                node.tag_name().name()
            )));
        }
        if node
            .attributes()
            .any(|a| matches!(a.name(), "href" | "src" | "style") || a.name().starts_with("on"))
        {
            return Err(conversion(
                "external or interactive MathML attributes are unsupported",
            ));
        }
        let arity = match node.tag_name().name() {
            "mfrac" | "mroot" | "msub" | "msup" | "munder" | "mover" => Some(2),
            "msubsup" | "munderover" => Some(3),
            "mspace" | "mprescripts" | "none" => Some(0),
            _ => None,
        };
        if arity.is_some_and(|n| node.children().filter(|c| c.is_element()).count() != n) {
            return Err(conversion(format!(
                "invalid child count for MathML {}",
                node.tag_name().name()
            )));
        }
    }
    Ok(())
}
pub(super) fn run(
    input: MathInput,
    limits: MathLimits,
    rules: &MathRules,
) -> Result<MathConversion> {
    source(&input, limits)?;
    let mut diagnostics = Vec::new();
    let display = if input.display_kind == FormulaDisplayKind::Unknown {
        diagnostics.push(diagnostic("unknown-display-inline-v1","Unknown display context uses inline conversion semantics; recognition context is unchanged.")?);
        FormulaDisplayKind::Inline
    } else {
        input.display_kind
    };
    let mathml = if input.format == MathFormat::Mathml {
        input.text
    } else {
        let mut latex = input.text.trim();
        for (left, right) in [("$$", "$$"), ("\\[", "\\]"), ("\\(", "\\)"), ("$", "$")] {
            if latex.len() > left.len() + right.len()
                && latex.starts_with(left)
                && latex.ends_with(right)
            {
                let body = &latex[left.len()..latex.len() - right.len()];
                if !body.contains(left) && !body.contains(right) {
                    latex = body;
                    diagnostics.push(diagnostic("math-fence-removed-v1","Removed one enclosing math fence for expression parsing; original LaTeX is unchanged.")?);
                }
                break;
            }
        }
        preflight(latex, limits)?;
        let storage = pulldown_latex::Storage::new();
        let mut events = Vec::new();
        let mut depth = 0u32;
        for event in pulldown_latex::Parser::new(latex, &storage) {
            let event = event.map_err(conversion)?;
            match &event {
                pulldown_latex::Event::Begin(_) => {
                    depth += 1;
                }
                pulldown_latex::Event::End => {
                    depth = depth
                        .checked_sub(1)
                        .ok_or_else(|| conversion("unbalanced parser groups"))?;
                }
                _ => {}
            }
            if depth > limits.depth() || events.len() >= limits.nodes() as usize {
                return Err(limit("LaTeX parser complexity exceeds limits"));
            }
            events.push(Ok::<_, Error>(event));
        }
        let mut out = Bounded::new(limits.output_bytes() as usize);
        let rendered = pulldown_latex::write_mathml(
            &mut out,
            events.into_iter(),
            pulldown_latex::RenderConfig {
                display_mode: if display == FormulaDisplayKind::Displayed {
                    pulldown_latex::config::DisplayMode::Block
                } else {
                    pulldown_latex::config::DisplayMode::Inline
                },
                xml: true,
                ..Default::default()
            },
        );
        if let Err(e) = rendered {
            return Err(if out.exceeded {
                limit("MathML exceeds output byte limit")
            } else {
                conversion(e)
            });
        }
        String::from_utf8(out.finish()?).map_err(conversion)?
    };
    xml(&mathml, limits, display)?;
    Ok(MathConversion {
        mathml,
        display_kind: display,
        diagnostics,
        provenance: MathProvenance {
            sdk_version: ProfileId::new(env!("CARGO_PKG_VERSION"))?,
            profile: ProfileId::new(rules.profile())?,
            converter: ProfileId::new(if input.format == MathFormat::Latex {
                "pulldown-latex-0.8.0-strict-v1"
            } else {
                "presentation-mathml-checked-v1"
            })?,
            mathcat: ProfileId::new("mathcat-0.7.7-podoco-host-v1")?,
            rules_manifest_sha256: rules.manifest_sha256().clone(),
        },
    })
}
