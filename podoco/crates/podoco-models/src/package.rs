use podoco::{ModelBundle, formula::FormulaBundle, math::MathRules};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    error::Error,
    fs,
    io::{Read, Write},
    path::{Component, Path, PathBuf},
};

type Result<T> = std::result::Result<T, Box<dyn Error>>;
const INDEX: &str = "package-index.json";
const LIMIT: u64 = 1024 * 1024;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Config {
    schema_version: u32,
    package: String,
    output: PathBuf,
    flutter_package: PathBuf,
    pack: Pack,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Pack {
    id: String,
    dart_name: String,
    platforms: Vec<String>,
    layout: Source,
    formula: Option<Source>,
    math: Option<Source>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Source {
    directory: PathBuf,
    manifest_sha256: String,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct FileEntry {
    size_bytes: u64,
    sha256: String,
}
#[derive(Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Index {
    generator: String,
    schema_version: u32,
    package: String,
    pack_id: String,
    platform: String,
    available: bool,
    files: BTreeMap<String, FileEntry>,
}

fn read_bounded(path: &Path) -> Result<Vec<u8>> {
    let mut bytes = Vec::new();
    fs::File::open(path)?
        .take(LIMIT + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() as u64 > LIMIT {
        return Err(format!("metadata exceeds 1 MiB: {}", path.display()).into());
    }
    Ok(bytes)
}
fn identifier(value: &str, dart: bool) -> bool {
    !value.is_empty()
        && value.len() <= 80
        && value.as_bytes()[0].is_ascii_lowercase()
        && value.bytes().all(|b| {
            b.is_ascii_lowercase()
                || b.is_ascii_digit()
                || b == b'_'
                || (dart && b.is_ascii_uppercase())
        })
        && ![
            "class", "default", "switch", "return", "null", "true", "false", "import", "export",
            "void", "final", "const", "static", "abstract", "extends", "new", "this", "super",
            "enum", "var", "in", "is", "as", "if", "else", "for", "while", "do", "try", "catch",
            "throw", "with", "typedef", "assert", "break", "case", "continue", "finally",
            "rethrow",
        ]
        .contains(&value)
}
fn relative_name(path: &Path) -> Result<String> {
    let mut parts = Vec::new();
    for component in path.components() {
        let Component::Normal(value) = component else {
            return Err("unsafe asset path".into());
        };
        let value = value.to_str().ok_or("non-UTF8 asset path")?;
        if value.contains(['\\', ':', '\0', '\n', '\r']) {
            return Err("unsafe asset path".into());
        }
        parts.push(value);
    }
    if parts.is_empty() {
        return Err("empty asset path".into());
    }
    Ok(parts.join("/"))
}
fn digest(path: &Path) -> Result<FileEntry> {
    let mut file = fs::File::open(path)?;
    let mut hash = Sha256::new();
    let mut size = 0u64;
    let mut buffer = [0u8; 64 * 1024];
    loop {
        let count = file.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        hash.update(&buffer[..count]);
        size = size.checked_add(count as u64).ok_or("asset too large")?;
    }
    Ok(FileEntry {
        size_bytes: size,
        sha256: format!("{:x}", hash.finalize()),
    })
}
fn inventory(
    root: &Path,
    directory: &Path,
    allow_file_links: bool,
) -> Result<BTreeMap<String, FileEntry>> {
    let mut files = BTreeMap::new();
    for entry in fs::read_dir(directory)? {
        let path = entry?.path();
        let kind = fs::symlink_metadata(&path)?.file_type();
        if kind.is_dir() {
            files.extend(inventory(root, &path, allow_file_links)?);
        } else if kind.is_file()
            || (allow_file_links && kind.is_symlink() && fs::metadata(&path)?.is_file())
        {
            files.insert(relative_name(path.strip_prefix(root)?)?, digest(&path)?);
        } else {
            return Err(format!("nonregular asset or directory link: {}", path.display()).into());
        }
    }
    Ok(files)
}
fn verify_component(kind: &str, root: &Path, expected: &str) -> Result<()> {
    let actual = match kind {
        "layout" => ModelBundle::verify(root)?
            .manifest_sha256()
            .as_str()
            .to_owned(),
        "formula" => FormulaBundle::verify(root)?
            .manifest_sha256()
            .as_str()
            .to_owned(),
        "math" => MathRules::verify(root)?
            .manifest_sha256()
            .as_str()
            .to_owned(),
        _ => return Err("unknown component".into()),
    };
    if actual != expected {
        return Err(format!("{kind} manifest differs from configured pin").into());
    }
    Ok(())
}
fn components(config: &Config) -> Vec<(&str, &Source)> {
    let mut result = vec![("layout", &config.pack.layout)];
    if let Some(source) = &config.pack.formula {
        result.push(("formula", source));
    }
    if let Some(source) = &config.pack.math {
        result.push(("math", source));
    }
    result
}
fn dependency_path(output: &Path, dependency: &Path) -> Result<String> {
    let base: Vec<_> = output.components().collect();
    let target: Vec<_> = dependency.components().collect();
    let shared = base.iter().zip(&target).take_while(|(a, b)| a == b).count();
    if shared == 0 {
        return Err("generated package and SDK must share a filesystem root".into());
    }
    let mut relative = PathBuf::new();
    for _ in shared..base.len() {
        relative.push("..");
    }
    for component in &target[shared..] {
        relative.push(component.as_os_str());
    }
    Ok(relative
        .to_str()
        .ok_or("non-UTF8 SDK path")?
        .replace('\\', "/"))
}
fn write(path: &Path, bytes: impl AsRef<[u8]>) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let mut file = fs::OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(path)?;
    file.write_all(bytes.as_ref())?;
    Ok(())
}
fn verify_generated(output: &Path, package: &str) -> Result<Index> {
    if fs::symlink_metadata(output)?.is_symlink() {
        return Err("generated output is a symlink".into());
    }
    let index: Index = serde_json::from_slice(&read_bounded(&output.join(INDEX))?)?;
    if index.generator != "podoco-models" || index.schema_version != 1 || index.package != package {
        return Err("existing output is not this tool's generated package".into());
    }
    let mut actual = inventory(output, output, false)?;
    actual.remove(INDEX);
    if actual != index.files {
        return Err(
            "existing generated output has changed or unlisted files; preserve and inspect it"
                .into(),
        );
    }
    Ok(index)
}

pub(super) fn prepare(config_path: &Path, platform: &str, replace: bool) -> Result<Index> {
    let config_path = fs::canonicalize(config_path)?;
    let base = config_path.parent().ok_or("config has no parent")?;
    let value: serde_yaml_ng::Value = serde_yaml_ng::from_slice(&read_bounded(&config_path)?)?;
    let config: Config = serde_yaml_ng::from_value(value)?;
    if config.schema_version != 1
        || !identifier(&config.package, false)
        || !identifier(&config.pack.dart_name, true)
        || config.pack.id.is_empty()
        || config.pack.id.len() > 128
        || config.pack.platforms != ["macos-arm64"]
        || ![
            "macos-arm64",
            "macos-x64",
            "windows-arm64",
            "windows-x64",
            "linux-arm64",
            "linux-x64",
        ]
        .contains(&platform)
    {
        return Err("unsupported packaging configuration or platform".into());
    }
    for (_, source) in components(&config) {
        if source.manifest_sha256.len() != 64
            || !source
                .manifest_sha256
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        {
            return Err("expected lowercase SHA-256 manifest pin".into());
        }
    }
    let requested = base.join(&config.output);
    let name = requested
        .file_name()
        .ok_or("output must name a package directory")?;
    let parent = requested.parent().ok_or("output must have a parent")?;
    fs::create_dir_all(parent)?;
    let output = fs::canonicalize(parent)?.join(name);
    let dependency = fs::canonicalize(base.join(&config.flutter_package))?;
    if output == dependency || dependency.starts_with(&output) || config_path.starts_with(&output) {
        return Err("output overlaps SDK or config".into());
    }
    let lock_path = output.with_file_name(format!(".{}.prepare-lock", name.to_string_lossy()));
    fs::create_dir(&lock_path).map_err(|e| {
        format!(
            "cannot reserve preparation lock {}: {e}",
            lock_path.display()
        )
    })?;
    struct Lock(PathBuf);
    impl Drop for Lock {
        fn drop(&mut self) {
            let _ = fs::remove_dir(&self.0);
        }
    }
    let _lock = Lock(lock_path);
    let previous = if output.exists() || output.is_symlink() {
        Some(verify_generated(&output, &config.package)?)
    } else {
        None
    };
    let staging = tempfile::Builder::new()
        .prefix(".podoco-assets-")
        .tempdir_in(output.parent().unwrap())?;
    let stage = staging.path().join("package");
    fs::create_dir(&stage)?;
    let available = config.pack.platforms.iter().any(|p| p == platform);
    if available {
        for (kind, source) in components(&config) {
            let root = fs::canonicalize(base.join(&source.directory))?;
            if root.starts_with(&output) || output.starts_with(&root) {
                return Err("output overlaps model source".into());
            }
            verify_component(kind, &root, &source.manifest_sha256)?;
            let before = inventory(&root, &root, true)?;
            let destination = stage.join("models").join(kind);
            fs::create_dir_all(&destination)?;
            for (path, expected) in &before {
                let target = destination.join(path);
                fs::create_dir_all(target.parent().unwrap())?;
                // Rust's macOS implementation attempts clonefile; other hosts
                // stream through the native copy operation. Output never links.
                fs::copy(root.join(path), &target)?;
                if digest(&target)? != *expected {
                    return Err("copied asset changed".into());
                }
            }
            verify_component(kind, &destination, &source.manifest_sha256)?;
            if inventory(&root, &root, true)? != before {
                return Err("source changed during preparation".into());
            }
        }
    }
    write(&stage.join("LICENSE"), include_bytes!("../../../LICENSE"))?;
    let mut notices = "# Bundled analysis assets\n\nPodoco: Apache-2.0. These model profiles remain experimental.\n".to_owned();
    if available {
        notices.push_str("\nPP-DocLayoutV3, PaddlePaddle: Apache-2.0 (pinned model-card declaration); see models/layout/checkpoint/README.md.\n");
        if config.pack.formula.is_some() {
            notices.push_str("\nPP-FormulaNet_plus-L, PaddlePaddle: Apache-2.0 (pinned model contract); see models/formula/checkpoint/README.md.\n");
        }
        if config.pack.math.is_some() {
            notices
                .push_str("\nMathCAT 0.7.7 rules: MIT; full license is in models/math/LICENSE.\n");
        }
    }
    write(&stage.join("MODEL_NOTICES.md"), notices)?;
    let descriptor = |kind: &str, source: &Source| serde_json::json!({"directory":kind,"manifestSha256":source.manifest_sha256});
    let catalog = serde_json::json!({"schema_version":1,"id":config.pack.id,"platforms":if available {config.pack.platforms.clone()} else {vec![]},"layout":descriptor("layout", &config.pack.layout),"formula":config.pack.formula.as_ref().map(|s|descriptor("formula",s)),"math":config.pack.math.as_ref().map(|s|descriptor("math",s))});
    write(
        &stage.join("models/pack.json"),
        serde_json::to_vec_pretty(&catalog)?,
    )?;
    let catalog_hash = digest(&stage.join("models/pack.json"))?.sha256;
    let dart = format!(
        "// Generated by podoco-models. Do not edit.\nimport 'package:podoco_flutter/podoco_flutter.dart';\n\nabstract final class AppAnalysisPacks {{\n  static const {} = BundledAnalysisPack(\n    package: {},\n    assetRoot: 'models',\n    catalogSha256: {},\n  );\n}}\n",
        config.pack.dart_name,
        serde_json::to_string(&config.package)?,
        serde_json::to_string(&catalog_hash)?
    );
    write(&stage.join("lib/app_models.dart"), dart)?;
    let assets: Vec<_> = inventory(&stage, &stage, false)?
        .keys()
        .filter(|p| !p.starts_with("lib/"))
        .cloned()
        .collect();
    let pubspec = serde_json::json!({"name":config.package,"version":"0.1.0","publish_to":"none","environment":{"sdk":">=3.13.0 <4.0.0","flutter":">=3.47.5"},"dependencies":{"flutter":{"sdk":"flutter"},"podoco_flutter":{"path":dependency_path(&output,&dependency)?}},"flutter":{"assets":assets}});
    write(
        &stage.join("pubspec.yaml"),
        serde_yaml_ng::to_string(&pubspec)?,
    )?;
    let index = Index {
        generator: "podoco-models".into(),
        schema_version: 1,
        package: config.package.clone(),
        pack_id: config.pack.id,
        platform: platform.into(),
        available,
        files: inventory(&stage, &stage, false)?,
    };
    write(&stage.join(INDEX), serde_json::to_vec_pretty(&index)?)?;
    verify_generated(&stage, &config.package)?;
    if previous.as_ref() == Some(&index) {
        return Ok(index);
    }
    if previous.is_some() && !replace {
        return Err(
            "generated inputs differ; use --replace to rebuild this verified tool-owned package"
                .into(),
        );
    }
    let backup = staging.path().join("previous");
    if previous.is_some() {
        if previous.as_ref() != Some(&verify_generated(&output, &config.package)?) {
            return Err("existing output changed during preparation".into());
        }
        fs::rename(&output, &backup)?;
    }
    if let Err(error) = fs::rename(&stage, &output) {
        if backup.exists()
            && let Err(restore) = fs::rename(&backup, &output)
        {
            let preserved = staging.keep();
            return Err(format!(
                "publication failed: {error}; restoration failed: {restore}; preserved previous package at {}",
                preserved.join("previous").display()
            ).into());
        }
        return Err(error.into());
    }
    // Only the verified previous generated tree is removed, after publication.
    Ok(index)
}

#[cfg(test)]
mod tests;
