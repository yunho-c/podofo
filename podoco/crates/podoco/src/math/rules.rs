//! Immutable rule assets, verified against the exact checked-in inventory.
use crate::{Error, ErrorCode, Result, bundle::LockedFile, domain::Sha256Digest};
use serde::Deserialize;
use std::{
    collections::HashSet,
    fs,
    io::Read,
    path::{Path, PathBuf},
};

pub(super) const PIN: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../model-manifests/mathcat-rules-v1.yaml"
));

#[derive(Deserialize)]
struct Manifest {
    id: String,
    profile: String,
    files: Vec<LockedFile>,
}

/// Verified offline MathCAT rules. Keep files and link targets immutable in use.
#[derive(Clone, Debug)]
pub struct MathRules {
    root: PathBuf,
    id: String,
    profile: String,
    hash: Sha256Digest,
}
impl MathRules {
    #[cfg(test)]
    pub(super) fn testing() -> Self {
        Self {
            root: PathBuf::new(),
            id: "test-rules".into(),
            profile: "test-math-v1".into(),
            hash: Sha256Digest::of_bytes(b"test"),
        }
    }
    /// Verify the exact pinned manifest, inventory, sizes and hashes without downloads.
    pub fn verify(directory: impl AsRef<Path>) -> Result<Self> {
        let root = directory
            .as_ref()
            .canonicalize()
            .map_err(|e| Error::io(directory.as_ref(), e))?;
        let path = root.join("podoco-rules.yaml");
        let mut bytes = Vec::new();
        fs::File::open(&path)
            .map_err(|e| Error::io(&path, e))?
            .take(PIN.len() as u64 + 1)
            .read_to_end(&mut bytes)
            .map_err(|e| Error::io(&path, e))?;
        if bytes != PIN.as_bytes() {
            return Err(Error::new(
                ErrorCode::InvalidManifest,
                "MathCAT rule manifest differs from the pinned contract",
            ));
        }
        let manifest: Manifest = serde_yaml_ng::from_str(PIN)
            .map_err(|e| Error::new(ErrorCode::InvalidManifest, e.to_string()))?;
        let mut actual = HashSet::new();
        crate::bundle::inventory(&root, &root, &mut actual)?;
        let mut expected: HashSet<_> = manifest.files.iter().map(|f| f.path.clone()).collect();
        expected.insert("podoco-rules.yaml".into());
        if actual != expected {
            return Err(Error::new(
                ErrorCode::InvalidAsset,
                "MathCAT rule inventory differs from its pin",
            ));
        }
        for file in &manifest.files {
            crate::bundle::verify_file(&root.join(&file.path), file)?;
        }
        Ok(Self {
            root,
            id: manifest.id,
            profile: manifest.profile,
            hash: Sha256Digest::of_bytes(PIN.as_bytes()),
        })
    }
    /// Canonical verified asset directory, containing `Rules` and its license.
    pub fn directory(&self) -> &Path {
        &self.root
    }
    /// Pinned rule version identity.
    pub fn id(&self) -> &str {
        &self.id
    }
    /// Effective converter/MathCAT integration profile.
    pub fn profile(&self) -> &str {
        &self.profile
    }
    /// Exact manifest identity for derived speech caches.
    pub fn manifest_sha256(&self) -> &Sha256Digest {
        &self.hash
    }
}
