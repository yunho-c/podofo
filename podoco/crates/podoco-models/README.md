# Podoco model packaging

`podoco-models` prepares an offline Flutter asset package from verified local
bundles. It does not convert or download models. The application owns model
selection and redistribution; the SDK verifies and loads the selected assets.

From the Podoco workspace:

```sh
cargo run --locked --release -p podoco-models -- prepare-flutter \
  --config ../podofo_frontend_one/podoco-models.yaml --platform macos-arm64
```

The YAML configuration has schema version 1, a generated package name and output
directory, a relative `flutter_package` SDK path, and one named pack. A pack has
an ID, Dart identifier, `platforms: [macos-arm64]`, a required layout component,
and optional formula and math components. Each component specifies a local
directory and an exact lowercase manifest SHA-256. Paths resolve relative to the
configuration file. See the checked-in [PoDoFo configuration](../../../../podofo_frontend_one/podoco-models.yaml).

The tool verifies every component with the public Rust SDK, materializes file
symlinks as regular files, re-verifies the staged output, and checks that sources
did not change during copying. Directory links and special files are rejected.
Model payloads use native file copies (APFS clones where the OS supports them).
Every nested asset is explicitly listed in `pubspec.yaml`, including all files
inside compiled Core ML directories. The generated `AppAnalysisPacks` descriptor
pins the catalog; the catalog pins each component manifest. Component manifests
already pin payload hashes. Licenses, notices and checkpoint metadata are retained.

`windows-x64`, `windows-arm64`, `linux-x64`, `linux-arm64`, and `macos-x64` generate
a small unavailable pack with the same Dart API, without reading the model
sources. This keeps ordinary reader builds possible on unsupported hosts.

Preparation uses a sibling directory lock and staging directory. Identical inputs
are idempotent. Changed inputs require `--replace`, which only replaces a complete,
unchanged, tool-owned package. Unlisted files or modified output cause refusal,
even with `--replace`. Publication uses same-filesystem renames; a failed rename
attempts rollback, preserving the backup if restoration fails. This is not a
crash-atomic two-directory transaction: after interruption, inspect the lock,
staging tree and any `previous` backup before recovering them. Never blindly
delete a stale lock or unknown output.

`package-index.json` records every generated file for build audits. The manifest
and payloads are app assets; the generator index and Dart source are build inputs.
Changing pack contents means rebuilding the application. There is no runtime
installer, writable model store, extraction step or network fallback.

Validation:

```sh
cargo test --locked -p podoco-models
cargo clippy --locked -p podoco-models --all-targets -- -D warnings
```
