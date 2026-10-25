# PoDoFo

A Flutter desktop PDF reader with tabs, search, outlines, thumbnails, persistent
PDF highlights, and local MLSR paper narration on macOS Apple Silicon.

The repository also contains [Podoco](podoco/README.md), an independent
Rust-first document analysis SDK. Its initial scaffold includes Rust, C, and
Dart APIs and development checks; model inference is not implemented yet.

The app lives in `podofo_frontend_one`. Use Flutter **3.47.5** and see
[development and verification](docs/development.md) for setup, tests, and controls.
For MLSR dependencies and the current macOS 15+ build, follow the
[paper narration setup](docs/tts-implementation.md#build-preparation) before
resolving Flutter packages. See the [listening guide](docs/listening.md) for use
and the [qualification record](docs/tts-qualification.md) for measured limits.
The [modernization notes](docs/modernization.md) describe the dependency migration,
data compatibility, saving behavior, and current platform limits.

Highlighting, saving, and macOS Apple Silicon listening are implemented.
AI tools, study tools, extensions, timeline, utilities, print, and export are
visibly unavailable.
Windows is the locally validated desktop target.
