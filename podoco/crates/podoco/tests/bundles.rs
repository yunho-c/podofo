//! Offline asset integrity and preparation tests using explicitly synthetic payloads.
use podoco::{
    ErrorCode,
    bundle::*,
    domain::Sha256Digest,
    results::{FormulaDisplayKind, RegionCategory},
};
use std::{
    fs,
    path::{Path, PathBuf},
};

struct Fixture {
    directory: tempfile::TempDir,
    manifest_path: PathBuf,
    exports: PathBuf,
    checkpoint: PathBuf,
    manifest: BundleManifest,
}
impl Fixture {
    fn new() -> Self {
        let directory = tempfile::tempdir().unwrap();
        let exports = directory.path().join("exports");
        let checkpoint = directory.path().join("checkpoint");
        let manifest_path = directory.path().join("fixture.yaml");
        let mut manifest = BundleManifest::parse(PP_DOCLAYOUT_V3_MANIFEST.as_bytes()).unwrap();
        // Test-only payloads exercise integrity against a trusted inventory.
        // They are not executable models or a substitute for real-asset verification.
        for artifact in manifest.artifacts.values_mut() {
            artifact.files = vec![LockedFile {
                path: "nested/fixture.bin".into(),
                size_bytes: 7,
                sha256: Sha256Digest::of_bytes(b"fixture"),
            }];
            let root = match artifact.source {
                ArtifactSource::Export => exports.join(&artifact.path),
                ArtifactSource::Checkpoint => checkpoint.clone(),
            };
            fs::create_dir_all(root.join("nested")).unwrap();
            fs::write(root.join("nested/fixture.bin"), b"fixture").unwrap();
        }
        fs::write(&manifest_path, serde_yaml_ng::to_string(&manifest).unwrap()).unwrap();
        Self {
            directory,
            manifest_path,
            exports,
            checkpoint,
            manifest,
        }
    }
    fn prepare(&self, name: &str, mode: PrepareMode) -> podoco::Result<ModelBundle> {
        prepare(
            &self.manifest_path,
            &self.exports,
            &self.checkpoint,
            &self.directory.path().join(name),
            mode,
        )
    }
    fn payload(&self, root: &Path) -> PathBuf {
        let a = &self.manifest.artifacts["compiled"];
        root.join(&a.path).join(&a.files[0].path)
    }
}

#[test]
fn pinned_manifest_has_complete_mapping_and_explicit_layout_only_contract() {
    let manifest = BundleManifest::parse(PP_DOCLAYOUT_V3_MANIFEST.as_bytes()).unwrap();
    assert_eq!(manifest.profile.classes.len(), 25);
    assert_eq!(
        manifest.class(5).unwrap().display_kind,
        Some(FormulaDisplayKind::Displayed)
    );
    assert_eq!(
        manifest.class(15).unwrap().display_kind,
        Some(FormulaDisplayKind::Inline)
    );
    assert_eq!(
        manifest.class(11).unwrap().category,
        RegionCategory::FormulaNumber
    );
    assert_eq!(manifest.class(15).unwrap().label, "formula");
    assert_eq!(manifest.class(15).unwrap().native_subtype, "inline_formula");
    assert!(manifest.class(999).is_none());
    assert!(!manifest.profile.capabilities.formula_recognition);
    assert_eq!(manifest.profile.outputs[3].shape, [1, 300, 200, 200]);
}

#[test]
fn copied_bundle_is_relocatable_and_preserves_raw_manifest_hash() {
    let fixture = Fixture::new();
    let bundle = fixture.prepare("bundle", PrepareMode::Copy).unwrap();
    let mut options = podoco::AnalysisOptions::new(
        podoco::ProfileId::new(&bundle.manifest().profile.id).unwrap(),
    );
    assert_eq!(
        bundle.validate_options(&options).unwrap_err().code,
        ErrorCode::UnsupportedCapability
    );
    options.formula_scope = podoco::FormulaScope::None;
    bundle.validate_options(&options).unwrap();
    options.profile = podoco::ProfileId::new("wrong-profile").unwrap();
    assert_eq!(
        bundle.validate_options(&options).unwrap_err().code,
        ErrorCode::InvalidInput
    );
    let expected = Sha256Digest::of_bytes(&fs::read(&fixture.manifest_path).unwrap());
    assert_eq!(bundle.manifest_sha256(), &expected);
    let relocated = fixture.directory.path().join("relocated");
    fs::rename(bundle.directory(), &relocated).unwrap();
    ModelBundle::verify(&relocated).unwrap();
    assert!(
        !fs::symlink_metadata(fixture.payload(&relocated))
            .unwrap()
            .is_symlink()
    );
    fs::write(fixture.payload(&relocated), b"changed").unwrap();
    assert_eq!(
        ModelBundle::verify(&relocated).unwrap_err().code,
        ErrorCode::InvalidAsset
    );
}

#[test]
fn missing_and_unlisted_payloads_are_rejected() {
    let fixture = Fixture::new();
    let bundle = fixture.prepare("bundle", PrepareMode::Copy).unwrap();
    let payload = fixture.payload(bundle.directory());
    let extra = payload.with_file_name("extra.bin");
    fs::write(&extra, b"extra").unwrap();
    assert!(ModelBundle::verify(bundle.directory()).is_err());
    fs::remove_file(extra).unwrap();
    fs::remove_file(payload).unwrap();
    assert!(ModelBundle::verify(bundle.directory()).is_err());
}

#[test]
fn manifest_rejects_duplicate_keys_bad_paths_and_contract_drift() {
    let fixture = Fixture::new();
    for path in [
        "../escape",
        "/absolute",
        "a/../escape",
        "a\\b",
        "C:/escape",
        "a//b",
    ] {
        let mut manifest = fixture.manifest.clone();
        manifest.artifacts.get_mut("compiled").unwrap().files[0].path = path.into();
        assert!(
            BundleManifest::parse(serde_yaml_ng::to_string(&manifest).unwrap().as_bytes()).is_err(),
            "{path}"
        );
    }
    let duplicate = format!("{}\nschema_version: 1\n", PP_DOCLAYOUT_V3_MANIFEST);
    assert!(BundleManifest::parse(duplicate.as_bytes()).is_err());
    let nested_duplicate =
        PP_DOCLAYOUT_V3_MANIFEST.replacen("  top_k: 300", "  top_k: 300\n  top_k: 300", 1);
    assert_ne!(nested_duplicate, PP_DOCLAYOUT_V3_MANIFEST);
    assert!(BundleManifest::parse(nested_duplicate.as_bytes()).is_err());
    let mut manifest = fixture.manifest.clone();
    manifest.profile.input.shape[3] = 640;
    assert!(
        BundleManifest::parse(serde_yaml_ng::to_string(&manifest).unwrap().as_bytes()).is_err()
    );
    let mut manifest = fixture.manifest.clone();
    manifest.profile.capabilities.formula_recognition = true;
    assert!(
        BundleManifest::parse(serde_yaml_ng::to_string(&manifest).unwrap().as_bytes()).is_err()
    );
}

#[test]
fn preparation_never_overwrites_or_publishes_a_failed_bundle() {
    let fixture = Fixture::new();
    fixture.prepare("existing", PrepareMode::Copy).unwrap();
    let sentinel = fixture.directory.path().join("existing/sentinel");
    fs::write(&sentinel, b"preserve").unwrap();
    assert!(fixture.prepare("existing", PrepareMode::Copy).is_err());
    assert_eq!(fs::read(sentinel).unwrap(), b"preserve");
    fs::write(fixture.checkpoint.join("nested/fixture.bin"), b"tamper").unwrap();
    assert!(fixture.prepare("failed", PrepareMode::Copy).is_err());
    assert!(!fixture.directory.path().join("failed").exists());
    assert!(
        !fs::read_dir(fixture.directory.path()).unwrap().any(|p| p
            .unwrap()
            .file_name()
            .to_string_lossy()
            .contains("staging"))
    );
}

#[cfg(unix)]
#[test]
fn file_links_verify_target_bytes_but_directory_cycles_are_rejected() {
    let fixture = Fixture::new();
    let bundle = fixture.prepare("linked", PrepareMode::Link).unwrap();
    let payload = fixture.payload(bundle.directory());
    assert!(fs::symlink_metadata(&payload).unwrap().is_symlink());
    let graph = bundle
        .directory()
        .join(&fixture.manifest.artifacts["compiled"].path);
    let cycle = graph.join("cycle");
    std::os::unix::fs::symlink(&graph, &cycle).unwrap();
    assert!(ModelBundle::verify(bundle.directory()).is_err());
    fs::remove_file(cycle).unwrap();
    fs::write(
        fixture
            .exports
            .join(&fixture.manifest.artifacts["compiled"].path)
            .join("nested/fixture.bin"),
        b"changed",
    )
    .unwrap();
    assert!(ModelBundle::verify(bundle.directory()).is_err());
}

#[test]
fn runtime_profile_keeps_v0_verifiable_and_requires_explicit_revision() {
    let old = BundleManifest::parse(PP_DOCLAYOUT_V3_MANIFEST.as_bytes()).unwrap();
    let new = BundleManifest::parse(PP_DOCLAYOUT_V3_V1_MANIFEST.as_bytes()).unwrap();
    assert_eq!(old.artifacts, new.artifacts);
    assert_eq!(old.source, new.source);
    assert_ne!(old.profile.id, new.profile.id);
    let mut mixed = new;
    mixed.profile = old.profile;
    assert!(BundleManifest::parse(serde_yaml_ng::to_string(&mixed).unwrap().as_bytes()).is_err());
}
#[cfg(not(feature = "coreml"))]
#[test]
fn portable_session_reports_unavailable_backend_before_native_load() {
    let fixture = Fixture::new();
    let bundle = fixture.prepare("bundle", PrepareMode::Copy).unwrap();
    let options = podoco::AnalyzerOptions {
        compute_policy: podoco::options::ComputePolicy::CpuOnly,
        limits: podoco::ResourceLimits::new(1, 1, 1, 1, 1, 1, 1).unwrap(),
    };
    assert_eq!(
        podoco::LayoutSession::open(bundle, options)
            .err()
            .unwrap()
            .code,
        ErrorCode::UnsupportedCapability
    );
}
