//! Offline model-bundle preparation and verification; no inference backend needed.
use podoco::bundle::{ModelBundle, PrepareMode, prepare};
use std::{error::Error, path::Path};
fn main() -> std::result::Result<(), Box<dyn Error>> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let bundle = match args.as_slice() {
        [command,directory] if command == "verify" => ModelBundle::verify(directory)?,
        [command,manifest,exports,checkpoint,destination] if command == "prepare" =>
            prepare(Path::new(manifest),Path::new(exports),Path::new(checkpoint),Path::new(destination),PrepareMode::Link)?,
        [command,manifest,exports,checkpoint,destination,mode] if command == "prepare" && mode == "--copy" =>
            prepare(Path::new(manifest),Path::new(exports),Path::new(checkpoint),Path::new(destination),PrepareMode::Copy)?,
        _ => return Err("usage: model_bundle verify DIRECTORY | prepare MANIFEST EXPORT_ROOT CHECKPOINT_ROOT DESTINATION [--copy]".into()),
    };
    println!(
        "Verified {} ({}) at {}",
        bundle.manifest().id,
        bundle.manifest().qualification,
        bundle.directory().display()
    );
    println!("Manifest SHA-256: {}", bundle.manifest_sha256().as_str());
    println!(
        "Declared capabilities: {:?}; no runtime loaded",
        bundle.declared_capabilities()
    );
    Ok(())
}
