# Podoco for Flutter

`podoco_flutter` resolves immutable application resources and opens the public
Podoco Dart SDK. macOS 15+ on Apple Silicon is the initial supported platform.
Other desktop hosts can build the package but opening these models returns
`unsupported_capability`. QNN, mobile resource extraction, downloads and updates
are outside this implementation.

Prepare a local asset package with [`podoco-models`](../../crates/podoco-models/README.md)
before `flutter pub get`, then add the generated package and this Flutter package
as path dependencies. The generated package exports `AppAnalysisPacks` from
`app_models.dart`. Configure the underlying Dart native build with `coreml: true`
and `math: true`, or supply a compatible prebuilt library through the existing
`hooks.user_defines.podoco.native-library` setting. See the
[Dart SDK](../dart/README.md) and [PoDoFo example](../../../podofo_frontend_one/pubspec.yaml).

```dart
import 'package:podoco/podoco.dart';
import 'package:podoco_flutter/podoco_flutter.dart';
import 'package:podoco_app_models/app_models.dart';

Future<void> example(AnalyzerOptions options) async {
  final analyzer = await FlutterPodoco.openAnalyzer(
    pack: AppAnalysisPacks.documentAnalysis,
    options: options, // Explicit application budgets and compute policy.
    onProgress: (progress) {
      // locating, verifying, opening; metadata only, no tensor transfer.
    },
  );
  try {
    // Use analyzer's normal jobs and image ownership contracts.
  } finally {
    await analyzer.dispose();
  }

  // Math rules load independently: Copy LaTeX never needs this processor.
  final math = await FlutterPodoco.openMathProcessor(
    pack: AppAnalysisPacks.documentAnalysis,
  );
  await math.dispose();
}
```

Callers choose when to open, coalesce concurrent opens if needed, retain warm
engines, and dispose them. The loader itself does not create a global singleton
or load anything at app startup. The pure Dart and Rust path-based APIs remain
available for command-line clients and developer overrides.

Pass `includeFormula: false` to `openAnalyzer` for a layout-only engine. This
skips formula component verification and opening even when the catalog includes
FormulaNet. The default remains `true` for existing callers. Formula options are
rejected when formula loading is disabled. Math rules always load independently.
`FlutterModelLoader.readLayoutIdentity` checks the pinned catalog and the bounded
layout manifest (SHA-256, schema and identity fields) without reading model
payloads. Use this metadata only to compare compatible persisted results. It
returns `BundledLayoutIdentity`, not a `ModelBundle` that can open an analyzer.
Catalog/manifest corruption, unsupported platforms and linked component trees
still fail. Cached results can remain usable when payloads are absent; a new
inference request still requires full payload verification.

`FlutterModelLoader.verifyLayout` verifies all layout payloads and returns a
verified `ModelBundle` plus catalog metadata without opening Core ML or reading
formula/math payloads. `openAnalyzer` always takes this full verification path.

The macOS plugin returns paths under the running application's canonical bundle.
Only metadata crosses its method channel. No model bytes cross Dart, and models
are never copied into Application Support. The Dart loader verifies the bounded,
pinned catalog, rejects linked component trees, and invokes native manifest and
payload verification away from the UI isolate. It checks the opened engine's
manifest identity again before returning it. Missing or damaged assets produce
typed `PodocoException`s; they never trigger a search in the developer checkout.
Framework resource aliases may resolve internally within the app bundle.

`FlutterModelLoader(resources: ...)` accepts a `ModelResources` implementation
for tests or another embedding environment. Production Flutter callers normally
use `FlutterPodoco` with the default native resource locator. `locatePack` verifies
metadata only; opening performs component verification. A missing math component
does not prevent opening the layout/formula analyzer.

Run `flutter analyze` and `flutter test` in this directory for portable metadata,
platform-channel, corruption, relocation and missing-component tests. Actual
Core ML loading requires local model assets and an Apple Silicon host; PoDoFo's
release probe exercises the signed application's real plugin and native engines.
