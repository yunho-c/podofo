# Bundled Podoco assets

PoDoFo packages its experimental analysis models and MathCAT rules inside the
application. On macOS Apple Silicon, Analyze opens layout and formula models
lazily; Listen opens math rules lazily through the shared narration controller.
Copy LaTeX only needs recognition. Nothing is downloaded, and users do not choose
model folders in the default flow. The feature remains in Developer mode until
the existing quality and human acceptance gates pass.

## Build ownership

`podofo_frontend_one/podoco-models.yaml` is the application's selection and pinning
contract. The initial pack uses the existing mixed layout v1 profile, the complete
PP-FormulaNet_plus-L M6 bundle, and MathCAT 0.7.7 M7 rules. This packaging change
does not promote the unfinished FP32 layout revision or trim reference payloads.
The full pack adds approximately 1.03 GiB of uncompressed assets to the app.

The reusable Rust `podoco-models prepare-flutter` command creates the ignored
`.podoco/model_assets` Flutter package. `tool/prepare_podoco.py` prepares both
the native library and this asset package under its preparation lock. It fails
on a supported target if sources are missing, incompatible or not pinned. Other
desktop targets receive a model-free package and keep their ordinary reader
builds. `flutter pub get` follows preparation; Flutter bundles the generated
package's explicit nested asset list.

The generator is documented in [podoco-models](../podoco/crates/podoco-models/README.md).
The public loader API is documented in [podoco_flutter](../podoco/bindings/flutter/README.md).
Neither module imports PoDoFo application code. The existing C, Rust and pure Dart
path-based APIs and image ownership contracts remain unchanged.

## Runtime and replacement

The generated Dart descriptor pins `models/pack.json`; that catalog pins each
component manifest, which pins its payloads. The native plugin resolves assets
relative to the running application, including after relocation. The SDK verifies
and loads compiled Core ML directories directly. Application Support contains
derived page caches, not a second installed model tree. Core ML may maintain its
own framework caches; direct resource loading does not promise their absence.

The application shows preparation status, shares repeated Analyze/Listen requests,
and keeps warm engines until replacement or close. Cancel or document replacement
suppresses late analysis after a noninterruptible model open. A late engine is
disposed when its controller closes. Listen claims narration ownership before
math loading, so newer prose cannot be displaced by late equation preparation.

The collapsed **Model overrides** section remains for development. Choices are
session-local. **Use bundled models** retires custom engines, then restores lazy
defaults on the next Analyze/Listen. Failures stay visible and retry explicitly;
there is no automatic developer-path fallback. Missing math rules leave Copy
usable. Unsupported platforms keep the existing unavailable explanation.

## Release checks

The local Release build helper runs `tool/audit_podoco_macos.py` on Apple Silicon.
The audit compares the complete shipped asset inventory, sizes and hashes against
the generated index, checks native arm64 linkage and verifies sandboxed signing.
A missing asset or a link inside the model tree fails the build audit.

`tool/qualify_podoco_bundle.py` builds an instrumented entrypoint with the pinned
M8 PDF embedded at build time. It relocates the app, assigns a unique bundle ID
for a fresh sandbox, removes both network entitlements, and launches through
macOS Launch Services. The probe proves denial of existing developer model files
and a listening network socket, then runs the real loader, PDF renderer, analyzer,
Copy payload, MathCAT and muted MLSR playback. No model path is supplied. It
checks eight recognized formulas, exact first-formula LaTeX and speech text,
audio progress, initialization coalescing and native handle cleanup.

```sh
# From podofo_frontend_one/, after preparation and flutter pub get:
CARGO_INCREMENTAL=0 python3.13 tool/qualify_podoco_bundle.py \
  --output build/podoco-qualification/bundled-assets-NEW \
  --pdf build/podoco-qualification/m8-native-v3/recognized-page.pdf
```

The output must be new. Evidence includes source hashes (also recording dirty
inputs), signed bundle audits, runtime receipts and logs. The helper leaves an
ordinary reader app in its own `products/Release/PoDoFo.app`, using independent
Xcode intermediates. `FLUTTER_BIN` selects the pinned Flutter executable.
Muted playback and captured Copy payloads establish plumbing; they do not establish
human pronunciation acceptance or exercise the system clipboard UI.
