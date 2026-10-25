/// Dart bindings for Podoco's Rust-owned document analysis library.
///
/// The initial scaffold exposes library identity only. Document analysis and
/// model loading are not implemented yet.
library;

import 'package:ffi/ffi.dart';

import 'src/bindings.g.dart' as native;

/// The C ABI version understood by this package.
const supportedAbiVersion = 1;

/// The ABI version reported by the bundled native library.
int get nativeAbiVersion => native.podoco_abi_version();

/// The native library's version, after checking ABI compatibility.
///
/// Throws [UnsupportedError] if the library uses an unsupported ABI.
String get nativeVersion {
  final actual = nativeAbiVersion;
  if (actual != supportedAbiVersion) {
    throw UnsupportedError(
      'Podoco ABI $actual is incompatible with ABI $supportedAbiVersion.',
    );
  }
  return native.podoco_version().cast<Utf8>().toDartString();
}
