import 'package:flutter/services.dart';
import 'package:podoco/podoco.dart';

/// Generated identity of one immutable application asset pack.
class BundledAnalysisPack {
  final String package, assetRoot, catalogSha256;
  const BundledAnalysisPack({
    required this.package,
    required this.assetRoot,
    required this.catalogSha256,
  });
}

/// Platform resource lookup; payload bytes never cross the method channel.
abstract interface class ModelResources {
  Future<String> platformKey();
  Future<String?> locateDirectory(BundledAnalysisPack pack);
}

class NativeModelResources implements ModelResources {
  const NativeModelResources();
  static const channel = MethodChannel('dev.podoco.flutter/models');

  Future<String?> _call(String method, [Map<String, String>? arguments]) async {
    try {
      return await channel.invokeMethod<String>(method, arguments);
    } on MissingPluginException {
      throw const PodocoException(
        'unsupported_capability',
        'Bundled analysis currently requires macOS on Apple Silicon.',
      );
    } on PlatformException catch (error) {
      throw PodocoException(
        error.code,
        error.message ?? 'Model resource lookup failed',
      );
    }
  }

  @override
  Future<String> platformKey() async =>
      await _call('platform') ??
      (throw const PodocoException(
        'invalid_asset',
        'Missing resource platform',
      ));

  @override
  Future<String?> locateDirectory(BundledAnalysisPack pack) =>
      _call('locate', {'package': pack.package, 'assetRoot': pack.assetRoot});
}
