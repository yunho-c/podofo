//! Offline verification of the concrete PP-DocLayoutV3 bundle contract.
//!
//! Hashes establish integrity against a trusted manifest, not publisher
//! authenticity or executable-model validity. Keep payloads and symlink targets
//! immutable after verification. Loading and native tensor inspection belong to M2.
use crate::{
    Error, ErrorCode, Result,
    domain::Sha256Digest,
    options::Capabilities,
    results::{FormulaDisplayKind, RegionCategory},
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, HashSet},
    fs,
    io::Read,
    path::{Component, Path, PathBuf},
};

/// Filename of a prepared local bundle manifest.
pub const MANIFEST_NAME: &str = "podoco-bundle.yaml";
/// Pinned experimental profile. No ordinary build downloads its payloads.
pub const PP_DOCLAYOUT_V3_MANIFEST: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../model-manifests/pp-doclayout-v3-coreml.yaml"
));
const MANIFEST_LIMIT: u64 = 1024 * 1024;

/// Exact portable tensor interface.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TensorSpec {
    /// Runtime feature name.
    pub name: String,
    /// Interface dtype, independent of internal weight precision.
    pub dtype: String,
    /// Fixed dimensions in runtime order.
    pub shape: Vec<u32>,
}
/// Native label mapping; collapsed checkpoint labels are retained separately.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ClassMapping {
    /// Native numeric class.
    pub id: u32,
    /// Transformers checkpoint label.
    pub label: String,
    /// Distinct native subtype from pinned inference.yml.
    pub native_subtype: String,
    /// Compact public category.
    pub category: RegionCategory,
    /// Formula context; absent for non-formula regions.
    pub display_kind: Option<FormulaDisplayKind>,
}
/// Pinned preprocessing contract, not a runtime implementation.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Preprocessing {
    /// Pixel tensor channel order.
    pub color: String,
    /// Tensor layout.
    pub layout: String,
    /// Reference resizing implementation.
    pub resize: String,
    /// Rescale divisor.
    pub divisor: u32,
    /// Mean subtraction.
    pub mean: [f64; 3],
    /// Standard deviation division.
    pub std: [f64; 3],
    /// Composite background, in RGB bytes.
    pub background_rgb: [u8; 3],
}
/// Pinned postprocessing reproduction profile.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Postprocessing {
    /// Classification activation.
    pub activation: String,
    /// Number of flattened query/class candidates.
    pub top_k: u32,
    /// Inclusive detection-score cutoff.
    pub score_threshold: f64,
    /// Box coordinate encoding.
    pub boxes: String,
    /// Native order decoding algorithm identity.
    pub reading_order: String,
    /// Whether additional NMS is applied; false in the pinned baseline.
    pub additional_nms: bool,
}
/// Concrete supported layout profile.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LayoutProfile {
    /// Versioned profile identity.
    pub id: String,
    /// Adapter identity; not an indication that it has been implemented.
    pub adapter: String,
    /// Input tensor.
    pub input: TensorSpec,
    /// All exported tensors, including the full 48 MB mask output.
    pub outputs: Vec<TensorSpec>,
    /// Pinned preprocessing.
    pub preprocessing: Preprocessing,
    /// Pinned decoding.
    pub postprocessing: Postprocessing,
    /// Complete native class map.
    pub classes: Vec<ClassMapping>,
    /// Declared functionality for the planned adapter, not loaded runtime availability.
    pub capabilities: Capabilities,
}
/// Immutable upstream provenance.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Source {
    /// Upstream model repository.
    pub repository: String,
    /// Immutable checkpoint commit.
    pub revision: String,
    /// Model-card license declaration, separate from the SDK license.
    pub license: String,
    /// Hashes of original checkpoint files, including weights not shipped here.
    pub files: BTreeMap<String, Sha256Digest>,
}
/// Export and processor evidence, preserved separately from inference qualification.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ConversionProvenance {
    /// Export project commit.
    pub revision: String,
    /// Export source-file hashes.
    pub sources: BTreeMap<String, Sha256Digest>,
    /// Exact reference package versions.
    pub packages: BTreeMap<String, String>,
    /// Model implementation hash.
    pub model_source_sha256: Sha256Digest,
    /// Processor implementation hash.
    pub processor_source_sha256: Sha256Digest,
    /// Existing conversion report location within the source project.
    pub report: String,
}
/// Deployment requirements; they do not assert host/device qualification.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RuntimeContract {
    /// Initially coreml.
    pub kind: String,
    /// Minimum deployment version.
    pub macos: String,
    /// Export's minimum iOS version, currently unqualified by Podoco.
    pub ios: String,
    /// Export precision policy.
    pub precision: String,
}
/// A payload entry relative to its artifact directory.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LockedFile {
    /// Portable relative file path.
    pub path: String,
    /// Expected file length.
    pub size_bytes: u64,
    /// Expected SHA-256 of target bytes.
    pub sha256: Sha256Digest,
}
/// Source root used only by explicit local preparation.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ArtifactSource {
    /// Export root plus the artifact's path.
    Export,
    /// Explicit checkpoint root itself.
    Checkpoint,
}
/// A complete inventoried payload directory.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Artifact {
    /// Artifact kind: package, compiled graph, or processor metadata.
    pub kind: String,
    /// Relative destination directory.
    pub path: String,
    /// Explicit local preparation source.
    pub source: ArtifactSource,
    /// Complete file inventory, excluding regular .DS_Store metadata.
    pub files: Vec<LockedFile>,
}
/// Concrete YAML model description. Parse using [`BundleManifest::parse`].
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BundleManifest {
    /// Manifest format version, independent of result schema.
    pub schema_version: u32,
    /// Bundle identity.
    pub id: String,
    /// Experimental until separately promoted through model/native qualification.
    pub qualification: String,
    /// Original checkpoint provenance.
    pub source: Source,
    /// Export/reference provenance.
    pub conversion: ConversionProvenance,
    /// Runtime requirements.
    pub runtime: RuntimeContract,
    /// Concrete adapter contract.
    pub profile: LayoutProfile,
    /// Complete exported asset inventories.
    pub artifacts: BTreeMap<String, Artifact>,
}
fn manifest_error(message: impl Into<String>) -> Error {
    Error::new(ErrorCode::InvalidManifest, message)
}
fn asset_error(message: impl Into<String>) -> Error {
    Error::new(ErrorCode::InvalidAsset, message)
}
fn safe_path(value: &str) -> Result<()> {
    if value.is_empty()
        || value.contains(['\\', ':', '\0'])
        || value
            .split('/')
            .any(|p| p.is_empty() || p == "." || p == "..")
        || Path::new(value)
            .components()
            .any(|p| !matches!(p, Component::Normal(_)))
    {
        return Err(manifest_error(format!(
            "unsafe relative payload path: {value:?}"
        )));
    }
    Ok(())
}
impl BundleManifest {
    /// Parse bounded YAML, rejecting duplicate keys even in nested mappings,
    /// and validate against the supported adapter contract.
    pub fn parse(bytes: &[u8]) -> Result<Self> {
        if bytes.len() as u64 > MANIFEST_LIMIT {
            return Err(manifest_error("manifest exceeds 1 MiB"));
        }
        let value: serde_yaml_ng::Value =
            serde_yaml_ng::from_slice(bytes).map_err(|e| manifest_error(e.to_string()))?;
        let manifest: Self =
            serde_yaml_ng::from_value(value).map_err(|e| manifest_error(e.to_string()))?;
        manifest.validate()?;
        Ok(manifest)
    }
    fn validate(&self) -> Result<()> {
        let baseline: Self =
            serde_yaml_ng::from_str(PP_DOCLAYOUT_V3_MANIFEST).expect("checked-in profile");
        if self.schema_version != 1
            || self.id != baseline.id
            || self.qualification != "experimental"
            || self.profile != baseline.profile
            || self.source != baseline.source
            || self.runtime != baseline.runtime
            || self.conversion != baseline.conversion
        {
            return Err(manifest_error(
                "unsupported model, source, deployment, or profile contract",
            ));
        }
        if self.artifacts.keys().collect::<Vec<_>>()
            != baseline.artifacts.keys().collect::<Vec<_>>()
        {
            return Err(manifest_error(
                "bundle requires package, compiled graph, and checkpoint metadata",
            ));
        }
        let mut paths = HashSet::new();
        for (name, artifact) in &self.artifacts {
            let expected = &baseline.artifacts[name];
            if artifact.kind != expected.kind
                || artifact.source != expected.source
                || artifact.path != expected.path
            {
                return Err(manifest_error("unsupported artifact kind or location"));
            }
            safe_path(&artifact.path)?;
            if artifact.files.is_empty() {
                return Err(manifest_error("empty artifact inventory"));
            }
            for file in &artifact.files {
                safe_path(&file.path)?;
                if !paths.insert(format!("{}/{}", artifact.path, file.path)) {
                    return Err(manifest_error("duplicate payload path"));
                }
            }
        }
        Ok(())
    }
    /// Map a native class while preserving its original label separately.
    /// Unknown IDs normalize to `Other` at the adapter boundary.
    pub fn class(&self, id: u32) -> Option<&ClassMapping> {
        self.profile.classes.iter().find(|c| c.id == id)
    }
}

/// Verified local bytes and manifest, without a loaded native model.
#[derive(Clone, Debug)]
pub struct ModelBundle {
    root: PathBuf,
    manifest: BundleManifest,
    manifest_sha256: Sha256Digest,
}
impl ModelBundle {
    /// Read, validate, and hash all payloads without downloading or loading Core ML.
    pub fn verify(directory: impl AsRef<Path>) -> Result<Self> {
        let root =
            fs::canonicalize(directory.as_ref()).map_err(|e| Error::io(directory.as_ref(), e))?;
        let path = root.join(MANIFEST_NAME);
        let mut bytes = Vec::new();
        fs::File::open(&path)
            .map_err(|e| Error::io(&path, e))?
            .take(MANIFEST_LIMIT + 1)
            .read_to_end(&mut bytes)
            .map_err(|e| Error::io(&path, e))?;
        let manifest = BundleManifest::parse(&bytes)?;
        for artifact in manifest.artifacts.values() {
            verify_artifact(&root.join(&artifact.path), artifact)?;
        }
        Ok(Self {
            root,
            manifest,
            manifest_sha256: Sha256Digest::of_bytes(&bytes),
        })
    }
    /// Canonical local root. Payloads and targets must remain immutable while in use.
    pub fn directory(&self) -> &Path {
        &self.root
    }
    /// Verified manifest description.
    pub fn manifest(&self) -> &BundleManifest {
        &self.manifest
    }
    /// Hash of the original manifest bytes, not a semantic reserialization hash.
    pub fn manifest_sha256(&self) -> &Sha256Digest {
        &self.manifest_sha256
    }
    /// Declared adapter capabilities, not loaded runtime availability.
    pub fn declared_capabilities(&self) -> Capabilities {
        self.manifest.profile.capabilities
    }
    /// Validate the exact selected profile and declared operations before rendering.
    /// This does not establish that an inference runtime is available.
    pub fn validate_options(&self, options: &crate::AnalysisOptions) -> Result<()> {
        if options.profile.as_str() != self.manifest.profile.id {
            return Err(Error::input(
                "analysis profile does not match the verified bundle",
            ));
        }
        self.declared_capabilities().validate(options)
    }
}
fn verify_artifact(root: &Path, artifact: &Artifact) -> Result<()> {
    let metadata = fs::symlink_metadata(root).map_err(|e| Error::io(root, e))?;
    if !metadata.is_dir() {
        return Err(asset_error("artifact root must be a real directory"));
    }
    let mut found = HashSet::new();
    inventory(root, root, &mut found)?;
    let expected: HashSet<_> = artifact.files.iter().map(|f| f.path.clone()).collect();
    if found != expected {
        return Err(asset_error(format!(
            "missing/unexpected payloads in {}",
            root.display()
        )));
    }
    for file in &artifact.files {
        verify_file(&root.join(&file.path), file)?;
    }
    Ok(())
}
fn inventory(root: &Path, directory: &Path, files: &mut HashSet<String>) -> Result<()> {
    for entry in fs::read_dir(directory).map_err(|e| Error::io(directory, e))? {
        let path = entry.map_err(|e| Error::io(directory, e))?.path();
        let meta = fs::symlink_metadata(&path).map_err(|e| Error::io(&path, e))?;
        if meta.is_dir() {
            inventory(root, &path, files)?;
        } else {
            if meta.is_file() && path.file_name().is_some_and(|v| v == ".DS_Store") {
                continue;
            }
            if !fs::metadata(&path)
                .map_err(|e| Error::io(&path, e))?
                .is_file()
            {
                return Err(asset_error(
                    "only regular files and file symlinks are allowed",
                ));
            }
            let relative = path
                .strip_prefix(root)
                .map_err(|e| asset_error(e.to_string()))?;
            let relative = relative
                .to_str()
                .ok_or_else(|| asset_error("non-UTF-8 payload path"))?
                .replace('\\', "/");
            files.insert(relative);
        }
    }
    Ok(())
}
fn verify_file(path: &Path, expected: &LockedFile) -> Result<()> {
    if !fs::metadata(path)
        .map_err(|e| Error::io(path, e))?
        .is_file()
    {
        return Err(asset_error("payload must be a regular file"));
    }
    let file = fs::File::open(path).map_err(|e| Error::io(path, e))?;
    if !file.metadata().map_err(|e| Error::io(path, e))?.is_file() {
        return Err(asset_error("payload must be a regular file"));
    }
    let mut reader = file.take(expected.size_bytes.saturating_add(1));
    let mut hash = Sha256::new();
    let mut count = 0u64;
    let mut buffer = [0u8; 65536];
    loop {
        let n = reader.read(&mut buffer).map_err(|e| Error::io(path, e))?;
        if n == 0 {
            break;
        }
        count = count
            .checked_add(n as u64)
            .ok_or_else(|| asset_error("file size overflow"))?;
        hash.update(&buffer[..n]);
    }
    if count != expected.size_bytes || format!("{:x}", hash.finalize()) != expected.sha256.as_str()
    {
        return Err(asset_error(format!(
            "size or hash mismatch: {}",
            path.display()
        )));
    }
    Ok(())
}

/// Explicit payload preparation mode.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PrepareMode {
    /// Preserve storage by linking individual verified files.
    Link,
    /// Create independently relocatable payload files.
    Copy,
}
/// Prepare verified local exports and checkpoint metadata into a new bundle.
/// No downloads, overwrites, compilation, or inference are performed.
///
/// The staging directory is a sibling of the destination. Only this function's
/// newly created staging data is removed on failure; source assets are untouched.
pub fn prepare(
    manifest_path: &Path,
    export_root: &Path,
    checkpoint_root: &Path,
    destination: &Path,
    mode: PrepareMode,
) -> Result<ModelBundle> {
    let mut bytes = Vec::new();
    fs::File::open(manifest_path)
        .map_err(|e| Error::io(manifest_path, e))?
        .take(MANIFEST_LIMIT + 1)
        .read_to_end(&mut bytes)
        .map_err(|e| Error::io(manifest_path, e))?;
    let manifest = BundleManifest::parse(&bytes)?;
    if fs::symlink_metadata(destination).is_ok() {
        return Err(asset_error("destination already exists"));
    }
    let parent = destination
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    fs::create_dir_all(parent).map_err(|e| Error::io(parent, e))?;
    let name = destination
        .file_name()
        .and_then(|s| s.to_str())
        .ok_or_else(|| asset_error("invalid destination"))?;
    let staging = parent.join(format!(".{name}.podoco-staging-{}", std::process::id()));
    fs::create_dir(&staging).map_err(|e| Error::io(&staging, e))?;
    let work = (|| {
        for artifact in manifest.artifacts.values() {
            let source = match artifact.source {
                ArtifactSource::Export => export_root.join(&artifact.path),
                ArtifactSource::Checkpoint => checkpoint_root.to_path_buf(),
            };
            for file in &artifact.files {
                let original = source.join(&file.path);
                verify_file(&original, file)?;
                let target = staging.join(&artifact.path).join(&file.path);
                let target_parent = target
                    .parent()
                    .ok_or_else(|| asset_error("missing payload parent"))?;
                fs::create_dir_all(target_parent).map_err(|e| Error::io(target_parent, e))?;
                match mode {
                    PrepareMode::Copy => {
                        fs::copy(&original, &target).map_err(|e| Error::io(&target, e))?;
                    }
                    PrepareMode::Link => link_file(
                        &fs::canonicalize(&original).map_err(|e| Error::io(&original, e))?,
                        &target,
                    )?,
                }
            }
        }
        fs::write(staging.join(MANIFEST_NAME), &bytes).map_err(|e| Error::io(&staging, e))?;
        ModelBundle::verify(&staging)?;
        // Reserve a new directory rather than renaming over a concurrently
        // created destination. Publication uses a completion manifest last.
        fs::create_dir(destination).map_err(|e| Error::io(destination, e))?;
        let publish = (|| {
            for artifact in manifest.artifacts.values() {
                fs::rename(
                    staging.join(&artifact.path),
                    destination.join(&artifact.path),
                )
                .map_err(|e| Error::io(destination, e))?;
            }
            fs::rename(staging.join(MANIFEST_NAME), destination.join(MANIFEST_NAME))
                .map_err(|e| Error::io(destination, e))?;
            ModelBundle::verify(destination)
        })();
        if publish.is_err() {
            let _ = fs::remove_dir_all(destination);
        }
        publish
    })();
    let _ = fs::remove_dir_all(&staging);
    work
}
fn link_file(source: &Path, destination: &Path) -> Result<()> {
    #[cfg(unix)]
    {
        std::os::unix::fs::symlink(source, destination).map_err(|e| Error::io(destination, e))
    }
    #[cfg(windows)]
    {
        std::os::windows::fs::symlink_file(source, destination)
            .map_err(|e| Error::io(destination, e))
    }
    #[cfg(not(any(unix, windows)))]
    {
        let _ = (source, destination);
        Err(asset_error("file links unsupported; use copy mode"))
    }
}
