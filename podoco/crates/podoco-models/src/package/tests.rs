use super::*;
use podoco::{
    bundle::{BundleManifest, LockedFile, PP_DOCLAYOUT_V3_V1_MANIFEST},
    domain::Sha256Digest,
};

fn fixture() -> Result<(tempfile::TempDir, PathBuf)> {
    let root = tempfile::tempdir()?;
    fs::create_dir(root.path().join("sdk"))?;
    let source = root.path().join("source");
    fs::create_dir(&source)?;
    let mut manifest = BundleManifest::parse(PP_DOCLAYOUT_V3_V1_MANIFEST.as_bytes())?;
    for artifact in manifest.artifacts.values_mut() {
        artifact.files = vec![LockedFile {
            path: "nested/value.bin".into(),
            size_bytes: 5,
            sha256: Sha256Digest::of_bytes(b"bytes"),
        }];
        let path = source.join(&artifact.path).join("nested/value.bin");
        write(&path, b"bytes")?;
    }
    let path = source.join("podoco-bundle.yaml");
    write(&path, serde_yaml_ng::to_string(&manifest)?)?;
    let config = serde_json::json!({"schema_version":1,"package":"test_assets","output":"generated","flutter_package":"sdk","pack":{"id":"test-v1","dart_name":"documentAnalysis","platforms":["macos-arm64"],"layout":{"directory":"source","manifest_sha256":digest(&path)?.sha256}}});
    let config_path = root.path().join("models.yaml");
    write(&config_path, serde_yaml_ng::to_string(&config)?)?;
    Ok((root, config_path))
}

#[test]
fn nested_assets_pins_and_idempotent_relocation() -> Result<()> {
    let (root, config) = fixture()?;
    let first = prepare(&config, "macos-arm64", false)?;
    assert!(first.available);
    let output = root.path().join("generated");
    let pubspec: serde_json::Value =
        serde_yaml_ng::from_slice(&fs::read(output.join("pubspec.yaml"))?)?;
    assert!(
        pubspec["flutter"]["assets"]
            .as_array()
            .unwrap()
            .iter()
            .any(|p| p.as_str().unwrap().ends_with("nested/value.bin"))
    );
    assert!(
        !fs::read_to_string(output.join("lib/app_models.dart"))?
            .contains(root.path().to_str().unwrap())
    );
    assert_eq!(first, prepare(&config, "macos-arm64", false)?);
    fs::rename(&output, root.path().join("relocated"))?;
    verify_generated(&root.path().join("relocated"), "test_assets")?;
    ModelBundle::verify(root.path().join("relocated/models/layout"))?;
    Ok(())
}

#[test]
fn failures_and_explicit_replacement_preserve_previous_package() -> Result<()> {
    let (root, config) = fixture()?;
    let first = prepare(&config, "macos-arm64", false)?;
    let index = root.path().join("generated/package-index.json");
    let previous = fs::read(&index)?;
    fs::write(
        root.path()
            .join("source/optimized-mixed.mlmodelc/nested/value.bin"),
        b"wrong",
    )?;
    assert!(prepare(&config, "macos-arm64", true).is_err());
    assert_eq!(fs::read(&index)?, previous);
    assert!(prepare(&config, "windows-x64", false).is_err());
    let portable = prepare(&config, "windows-x64", true)?;
    assert!(!portable.available);
    assert_ne!(first, portable);
    assert!(!root.path().join("generated/models/layout").exists());
    write(&root.path().join("generated/user-file"), b"preserve")?;
    assert!(prepare(&config, "windows-x64", true).is_err());
    assert_eq!(
        fs::read(root.path().join("generated/user-file"))?,
        b"preserve"
    );
    Ok(())
}

#[test]
fn lock_and_config_validation_fail_without_overwrite() -> Result<()> {
    let (root, config) = fixture()?;
    fs::create_dir(root.path().join(".generated.prepare-lock"))?;
    assert!(prepare(&config, "windows-x64", false).is_err());
    fs::remove_dir(root.path().join(".generated.prepare-lock"))?;
    let original = fs::read_to_string(&config)?;
    fs::write(&config, format!("{original}\nschema_version: 1\n"))?;
    assert!(prepare(&config, "windows-x64", false).is_err());
    assert!(!root.path().join("generated").exists());
    Ok(())
}

#[cfg(unix)]
#[test]
fn file_links_materialize_but_directory_links_are_rejected() -> Result<()> {
    let (root, config) = fixture()?;
    let path = root
        .path()
        .join("source/optimized-mixed.mlmodelc/nested/value.bin");
    fs::remove_file(&path)?;
    write(&root.path().join("external"), b"bytes")?;
    std::os::unix::fs::symlink(root.path().join("external"), &path)?;
    prepare(&config, "macos-arm64", false)?;
    assert!(
        !fs::symlink_metadata(
            root.path()
                .join("generated/models/layout/optimized-mixed.mlmodelc/nested/value.bin")
        )?
        .is_symlink()
    );
    std::os::unix::fs::symlink(root.path().join("source"), root.path().join("source/cycle"))?;
    assert!(prepare(&config, "macos-arm64", true).is_err());
    verify_generated(&root.path().join("generated"), "test_assets")?;
    Ok(())
}
