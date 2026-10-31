//! Offline, immutable formula bundle verification.
use crate::{Error, ErrorCode, Result, bundle::LockedFile, domain::Sha256Digest};
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, HashSet},
    fs,
    io::Read,
    path::{Path, PathBuf},
};

/// Pinned export, checkpoint, processor and generation contract.
pub const PP_FORMULANET_CONTRACT: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../model-manifests/pp-formulanet-plus-l-coreml-v1.yaml"
));
/// Concrete deployed greedy-decoding profile.
pub const PROFILE: &str = "pp-formulanet-plus-l-transformers-5.8.1-greedy2048-v1";

/// Inventoried local formula payloads, prepared explicitly by the maintainer tool.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FormulaManifest {
    /// Manifest format.
    pub schema_version: u32,
    /// Pinned model identity.
    pub id: String,
    /// Pinned preprocessing and decoding identity.
    pub profile: String,
    /// Experimental until full deployment qualification.
    pub qualification: String,
    /// Exact checked-in model contract hash.
    pub contract_sha256: Sha256Digest,
    /// Host compiler/toolchain observations, separate from source-model provenance.
    pub compilation: BTreeMap<String, String>,
    /// Complete bundle inventory, excluding the manifest itself.
    pub files: Vec<LockedFile>,
}
/// Verified formula assets; verification never loads or downloads models.
#[derive(Clone, Debug)]
pub struct FormulaBundle {
    root: PathBuf,
    manifest: FormulaManifest,
    hash: Sha256Digest,
}
impl FormulaBundle {
    /// Verify a local prepared bundle. Keep its contents immutable while in use.
    pub fn verify(directory: impl AsRef<Path>) -> Result<Self> {
        let root =
            fs::canonicalize(directory.as_ref()).map_err(|e| Error::io(directory.as_ref(), e))?;
        let path = root.join(crate::bundle::MANIFEST_NAME);
        let mut bytes = Vec::new();
        fs::File::open(&path)
            .map_err(|e| Error::io(&path, e))?
            .take(1_048_577)
            .read_to_end(&mut bytes)
            .map_err(|e| Error::io(&path, e))?;
        if bytes.len() > 1_048_576 {
            return Err(invalid("formula manifest exceeds 1 MiB"));
        }
        let value: serde_yaml_ng::Value =
            serde_yaml_ng::from_slice(&bytes).map_err(|e| invalid(e.to_string()))?;
        let manifest: FormulaManifest =
            serde_yaml_ng::from_value(value).map_err(|e| invalid(e.to_string()))?;
        if manifest.schema_version != 1
            || manifest.id != "pp-formulanet-plus-l-coreml-v1"
            || manifest.profile != PROFILE
            || manifest.qualification != "experimental"
            || manifest.contract_sha256 != Sha256Digest::of_bytes(PP_FORMULANET_CONTRACT.as_bytes())
        {
            return Err(invalid("unsupported formula model contract"));
        }
        let pin: serde_json::Value =
            serde_yaml_ng::from_str(PP_FORMULANET_CONTRACT).expect("checked-in contract");
        let mut expected = HashSet::new();
        for file in &manifest.files {
            crate::bundle::safe_path(&file.path)?;
            if !expected.insert(file.path.clone()) || file.path == crate::bundle::MANIFEST_NAME {
                return Err(invalid("duplicate or reserved payload path"));
            }
            let upstream = file
                .path
                .strip_prefix("export/")
                .map(|p| &pin["artifacts"][p])
                .or_else(|| {
                    file.path
                        .strip_prefix("checkpoint/")
                        .map(|p| &pin["checkpoint"][p])
                });
            if let Some(entry) = upstream {
                if entry["sha256"].as_str() != Some(file.sha256.as_str())
                    || entry["bytes"].as_u64() != Some(file.size_bytes)
                {
                    return Err(invalid("formula payload differs from pinned source"));
                }
            } else if !["encoder", "decoder-c256", "decoder-c2048"]
                .iter()
                .any(|m| file.path.starts_with(&format!("compiled/{m}.mlmodelc/")))
            {
                return Err(invalid("unexpected formula payload location"));
            }
        }
        for (group, prefix) in [("artifacts", "export"), ("checkpoint", "checkpoint")] {
            for name in pin[group].as_object().expect("pinned inventory").keys() {
                if name != "model.safetensors" && !expected.contains(&format!("{prefix}/{name}")) {
                    return Err(invalid("missing pinned formula payload"));
                }
            }
        }
        for model in ["encoder", "decoder-c256", "decoder-c2048"] {
            if !expected.contains(&format!("compiled/{model}.mlmodelc/coremldata.bin")) {
                return Err(invalid("missing compiled formula model"));
            }
        }
        expected.insert(crate::bundle::MANIFEST_NAME.into());
        let mut found = HashSet::new();
        crate::bundle::inventory(&root, &root, &mut found)?;
        if found != expected {
            return Err(invalid("missing or unexpected formula bundle files"));
        }
        for file in &manifest.files {
            crate::bundle::verify_file(&root.join(&file.path), file)?;
        }
        Ok(Self {
            root,
            manifest,
            hash: Sha256Digest::of_bytes(&bytes),
        })
    }
    /// Canonical immutable asset root.
    pub fn directory(&self) -> &Path {
        &self.root
    }
    /// Verified manifest metadata.
    pub fn manifest(&self) -> &FormulaManifest {
        &self.manifest
    }
    /// Hash of original manifest bytes.
    pub fn manifest_sha256(&self) -> &Sha256Digest {
        &self.hash
    }
}
fn invalid(message: impl Into<String>) -> Error {
    Error::new(ErrorCode::InvalidManifest, message)
}
