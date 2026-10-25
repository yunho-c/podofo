# Podoco for Dart

Thin Dart bindings for Podoco's Rust library. The scaffold exposes library
identity only; document analysis and model loading are not implemented.

```dart
import 'package:podoco/podoco.dart';

void main() {
  print('Podoco $nativeVersion (C ABI $nativeAbiVersion)');
}
```

From this package directory:

```sh
dart pub get --enforce-lockfile
dart run example/version.dart
dart test
```

The native build hook compiles `podoco-ffi` using Cargo and bundles its shared
library. It needs the Podoco Rust workspace at `../..` and Rust on `PATH`.
It supports desktop host builds; mobile, web, cross-compilation, and static
linking through this hook are not configured. Linux targets use glibc.
No model weights are downloaded.

For a copied package without Rust sources, supply a matching native library
through the consuming application's `pubspec.yaml`:

```yaml
hooks:
  user_defines:
    podoco:
      native-library: /absolute/path/to/libpodoco_ffi.dylib
```

Use `libpodoco_ffi.so` on Linux or `podoco_ffi.dll` on Windows. The path must point
to a library built for the current platform and architecture. ABI compatibility
is checked before `nativeVersion` is returned.

For a future PoDoFo integration, the relative dependency from
`podofo_frontend_one/pubspec.yaml` will be:

```yaml
dependencies:
  podoco:
    path: ../podoco/bindings/dart
```

That dependency is not added yet. Flutter-specific resource handling will be
introduced separately if needed. This package is not published to pub.dev.
