//! Decode the pinned 50,000-token ByteLevel vocabulary and processor rules.
//! Rules adapted from Apache-2.0 PPFormulaNetProcessor (PaddlePaddle/Hugging Face).
use crate::{Error, ErrorCode, Result};
use fancy_regex::{Captures, Regex};
use std::{fs, path::Path};

pub(crate) const MAX_TEXT_BYTES: usize = 256 * 1024;
pub(crate) struct Decoder {
    tokens: Vec<Vec<u8>>,
    ansi: Regex,
    chinese: Regex,
    text: Regex,
    macros: Regex,
    rules: [Regex; 3],
}
fn invalid(message: impl Into<String>) -> Error {
    Error::new(ErrorCode::InvalidAsset, message)
}
fn regex(pattern: &str) -> Regex {
    Regex::new(pattern).expect("fixed processor regex")
}
fn bounded(s: String) -> Result<String> {
    if s.len() > MAX_TEXT_BYTES {
        Err(Error::new(
            ErrorCode::LimitExceeded,
            "formula text exceeds 256 KiB",
        ))
    } else {
        Ok(s)
    }
}
fn replace(re: &Regex, s: &str, mut f: impl FnMut(&Captures<'_>) -> String) -> Result<String> {
    let mut result = String::new();
    let mut offset = 0;
    for c in re.captures_iter(s) {
        let c = c.map_err(|e| Error::new(ErrorCode::InvalidResult, e.to_string()))?;
        let whole = c.get(0).expect("whole match");
        let replacement = f(&c);
        if result.len() + whole.start() - offset + replacement.len() > MAX_TEXT_BYTES {
            return Err(Error::new(
                ErrorCode::LimitExceeded,
                "formula normalization exceeds 256 KiB",
            ));
        }
        result.push_str(&s[offset..whole.start()]);
        result.push_str(&replacement);
        offset = whole.end();
    }
    result.push_str(&s[offset..]);
    bounded(result)
}
impl Decoder {
    pub(crate) fn load(path: &Path) -> Result<Self> {
        let bytes = fs::read(path).map_err(|e| Error::io(path, e))?;
        let data: serde_json::Value =
            serde_json::from_slice(&bytes).map_err(|e| invalid(e.to_string()))?;
        if data["decoder"]["type"] != "ByteLevel" || data["model"]["type"] != "BPE" {
            return Err(invalid("unsupported formula tokenizer"));
        }
        // GPT-2 ByteLevel's reversible byte alphabet; tokenization is unnecessary
        // for inference. The pinned tokenizer never needs a full BPE encoder.
        let mut alphabet = std::collections::HashMap::new();
        let mut extra = 0;
        for b in 0..=255u32 {
            let scalar = if (33..=126).contains(&b)
                || (161..=172).contains(&b)
                || (174..=255).contains(&b)
            {
                b
            } else {
                let c = 256 + extra;
                extra += 1;
                c
            };
            alphabet.insert(char::from_u32(scalar).expect("byte alphabet"), b as u8);
        }
        let vocab = data["model"]["vocab"]
            .as_object()
            .ok_or_else(|| invalid("missing vocabulary"))?;
        if vocab.len() != 50_000 {
            return Err(invalid("incorrect vocabulary size"));
        }
        let mut tokens = vec![Vec::new(); 50_000];
        let mut seen = vec![false; 50_000];
        for (token, id) in vocab {
            let i = id
                .as_u64()
                .filter(|&v| v < 50_000)
                .ok_or_else(|| invalid("invalid token ID"))? as usize;
            if seen[i] {
                return Err(invalid("duplicate token ID"));
            }
            seen[i] = true;
            if i >= 23 {
                tokens[i] = token
                    .chars()
                    .map(|c| {
                        alphabet
                            .get(&c)
                            .copied()
                            .ok_or_else(|| invalid("invalid ByteLevel character"))
                    })
                    .collect::<Result<_>>()?;
            }
        }
        Ok(Self::with_tokens(tokens))
    }
    fn with_tokens(tokens: Vec<Vec<u8>>) -> Self {
        Self {
            tokens,
            ansi: regex(r"\x1b\[((?:\d|;)*)([a-zA-Z])"),
            chinese: regex(r"\\text\s*\{([^{}]*[\u{4e00}-\u{9fff}]+[^{}]*)\}"),
            text: regex(r"(\\(operatorname|mathrm|text|mathbf)\s?\*? \{.*?\})"),
            macros: regex(r"(\\[a-zA-Z]+)\s(?=\w)|\\[a-zA-Z]+\s(?=\})"),
            rules: [
                regex(r"(?!\\ )([\W_^\d])\s+?([\W_^\d])"),
                regex(r"(?!\\ )([\W_^\d])\s+?([a-zA-Z])"),
                regex(r"([a-zA-Z])\s+?([\W_^\d])"),
            ],
        }
    }
    pub(crate) fn decode(&self, ids: &[u32]) -> Result<(String, String)> {
        let mut bytes = Vec::new();
        for &id in ids {
            let token = self
                .tokens
                .get(id as usize)
                .ok_or_else(|| invalid("token outside vocabulary"))?;
            if bytes.len() + token.len() > MAX_TEXT_BYTES {
                return Err(Error::new(
                    ErrorCode::LimitExceeded,
                    "formula text exceeds 256 KiB",
                ));
            }
            bytes.extend_from_slice(token);
        }
        let raw = bounded(String::from_utf8_lossy(&bytes).into_owned())?;
        let normalized = self.normalize(&raw)?;
        Ok((raw, normalized))
    }
    pub(crate) fn normalize(&self, raw: &str) -> Result<String> {
        if raw.len() > MAX_TEXT_BYTES {
            return Err(Error::new(
                ErrorCode::LimitExceeded,
                "formula text exceeds 256 KiB",
            ));
        }
        let unwrapped = replace(&self.chinese, raw, |c| c[1].to_string())?.replace('"', "");
        // plsfix 0.1.8 spells ESC as Rust's octal-looking "\\033" (NUL + 33).
        // Apply the pinned ftfy 6.1.1 ANSI rule before control removal.
        let unwrapped = replace(&self.ansi, &unwrapped, |_| String::new())?;
        let mut text = bounded(plsfix::fix_text(&unwrapped, None))?;
        let mut names = Vec::new();
        let mut name_bytes = 0;
        // Reproduce the reference's whole-string replacements, including its
        // macro placeholder behavior; qualify this against saved processor cases.
        let original = text.clone();
        for found in self.text.find_iter(&original) {
            let found = found.map_err(|e| invalid(e.to_string()))?;
            for captures in self.macros.captures_iter(found.as_str()) {
                let captures = captures.map_err(|e| invalid(e.to_string()))?;
                if let Some(m) = captures.get(1)
                    && ![r"\operatorname", r"\mathrm", r"\text", r"\mathbf"].contains(&m.as_str())
                {
                    text = bounded(
                        text.replace(m.as_str(), &format!("{}XXXXXXX", m.as_str()))
                            .replace(' ', ""),
                    )?;
                    name_bytes += text.len();
                    if name_bytes > MAX_TEXT_BYTES {
                        return Err(Error::new(
                            ErrorCode::LimitExceeded,
                            "formula macro normalization exceeds scratch budget",
                        ));
                    }
                    names.push(text.clone());
                }
            }
        }
        if !names.is_empty() {
            let mut names = names.into_iter();
            text = replace(&self.text, &text, |_| names.next().unwrap_or_default())?;
        }
        loop {
            let before = text.clone();
            for rule in &self.rules {
                text = replace(rule, &text, |c| format!("{}{}", &c[1], &c[2]))?;
            }
            if text == before {
                break;
            }
        }
        Ok(text.replace("XXXXXXX", " "))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn processor_rules_and_bounded_malformed_text() {
        let decoder = Decoder::with_tokens(vec![]);
        for (raw, expected) in [
            (r"\text {中文} + x = 1", "中文 +x=1"),
            ("x\x1b[31m + y\r\n", "x+y\n"),
            ("cafÃ©", "café"),
            ("e\u{301} + ﬁ + Ａ + ’", "é +fi+A+'"),
            (r"\frac { a } { b }", r"\frac{a}{b}"),
        ] {
            assert_eq!(decoder.normalize(raw).unwrap(), expected);
        }
        assert_eq!(
            decoder
                .normalize(&"x".repeat(MAX_TEXT_BYTES + 1))
                .unwrap_err()
                .code,
            ErrorCode::LimitExceeded
        );
        assert_eq!(
            decoder.decode(&[50000]).unwrap_err().code,
            ErrorCode::InvalidAsset
        );
    }
}
