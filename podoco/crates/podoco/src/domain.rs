//! Portable identities, immutable page descriptions, and content hashes.
use crate::{Error, PageSpace, Result};
use serde::{Deserialize, Serialize};
use std::{collections::HashSet, fmt};

macro_rules! string_id {
    ($name:ident, $doc:literal) => {
        #[doc = $doc]
        #[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
        #[serde(try_from = "String", into = "String")]
        pub struct $name(String);
        impl $name {
            /// Preserve a nonempty opaque identifier without normalizing its contents.
            pub fn new(value: impl Into<String>) -> Result<Self> {
                let value = value.into();
                if value.trim().is_empty() {
                    return Err(Error::input(concat!(
                        stringify!($name),
                        " must not be empty"
                    )));
                }
                Ok(Self(value))
            }
            /// Original identifier.
            pub fn as_str(&self) -> &str {
                &self.0
            }
        }
        impl TryFrom<String> for $name {
            type Error = Error;
            fn try_from(v: String) -> Result<Self> {
                Self::new(v)
            }
        }
        impl From<$name> for String {
            fn from(v: $name) -> Self {
                v.0
            }
        }
        impl fmt::Display for $name {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                f.write_str(&self.0)
            }
        }
    };
}
string_id!(
    DocumentId,
    "Application-defined document identity, never interpreted as a path."
);
string_id!(RevisionId, "Application-defined immutable source revision.");
string_id!(
    AnalysisId,
    "Opaque analysis identity; a retry must receive a new identity."
);
string_id!(
    ProfileId,
    "Versioned render, adapter, preprocessing, or decoding profile identity."
);

/// A document and the exact revision that supplied its pages.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct DocumentRef {
    /// Application document identity.
    pub id: DocumentId,
    /// Immutable application revision.
    pub revision: RevisionId,
}
impl DocumentRef {
    /// Validate both identity components.
    pub fn new(id: impl Into<String>, revision: impl Into<String>) -> Result<Self> {
        Ok(Self {
            id: DocumentId::new(id)?,
            revision: RevisionId::new(revision)?,
        })
    }
}

/// A zero-based page index within one document revision.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct PageKey {
    /// Owning document revision.
    pub document: DocumentRef,
    /// Zero-based source index; not the position in a requested subset.
    pub page_index: u32,
}

/// A lazy page description containing no raster data.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct PageDescriptor {
    /// Source identity.
    pub key: PageKey,
    /// Canonical logical page dimensions.
    pub space: PageSpace,
}

/// Validate an ordered page subset without reordering it.
pub fn validate_pages(document: &DocumentRef, pages: &[PageDescriptor]) -> Result<()> {
    let mut indices = HashSet::new();
    for page in pages {
        if &page.key.document != document {
            return Err(Error::input(
                "page belongs to a different document revision",
            ));
        }
        if !indices.insert(page.key.page_index) {
            return Err(Error::input("duplicate page index"));
        }
    }
    Ok(())
}

/// Region identity, stable only within one page of one analysis.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct RegionId(pub u32);

/// A lowercase, 64-digit SHA-256 digest.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
pub struct Sha256Digest(String);
impl Sha256Digest {
    /// Parse a canonical hexadecimal SHA-256 digest.
    pub fn new(value: impl Into<String>) -> Result<Self> {
        let value = value.into();
        if value.len() != 64
            || !value
                .bytes()
                .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
        {
            return Err(Error::input("expected lowercase SHA-256 hex"));
        }
        Ok(Self(value))
    }
    /// Hash bytes, without canonicalizing or reserializing them.
    pub fn of_bytes(value: &[u8]) -> Self {
        use sha2::{Digest, Sha256};
        Self(format!("{:x}", Sha256::digest(value)))
    }
    /// Canonical hexadecimal representation.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}
impl TryFrom<String> for Sha256Digest {
    type Error = Error;
    fn try_from(v: String) -> Result<Self> {
        Self::new(v)
    }
}
impl From<Sha256Digest> for String {
    fn from(v: Sha256Digest) -> Self {
        v.0
    }
}

/// A finite model-specific score, not necessarily a calibrated probability.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(try_from = "f64", into = "f64")]
pub struct Score(f64);
impl Score {
    /// Validate a finite score without inventing probability semantics.
    pub fn new(value: f64) -> Result<Self> {
        if !value.is_finite() {
            return Err(Error::input("score must be finite"));
        }
        Ok(Self(value))
    }
    /// Original numeric score.
    pub fn value(self) -> f64 {
        self.0
    }
}
impl TryFrom<f64> for Score {
    type Error = Error;
    fn try_from(v: f64) -> Result<Self> {
        Self::new(v)
    }
}
impl From<Score> for f64 {
    fn from(v: Score) -> Self {
        v.0
    }
}
