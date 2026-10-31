//! Explicit offline asset preparation. Ordinary SDK builds never run this tool.
mod package;

fn main() {
    if let Err(error) = run() {
        eprintln!("Podoco asset preparation failed: {error}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), Box<dyn std::error::Error>> {
    let mut args = std::env::args().skip(1);
    if args.next().as_deref() != Some("prepare-flutter") {
        return Err(
            "usage: podoco-models prepare-flutter --config FILE --platform PLATFORM [--replace]"
                .into(),
        );
    }
    let (mut config, mut platform, mut replace) = (None, None, false);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--config" if config.is_none() => config = Some(args.next().ok_or("missing config")?),
            "--platform" if platform.is_none() => {
                platform = Some(args.next().ok_or("missing platform")?)
            }
            "--replace" if !replace => replace = true,
            _ => return Err(format!("unknown or repeated argument: {arg}").into()),
        }
    }
    let report = package::prepare(
        std::path::Path::new(&config.ok_or("--config is required")?),
        &platform.ok_or("--platform is required")?,
        replace,
    )?;
    println!("{}", serde_json::to_string_pretty(&report)?);
    Ok(())
}
