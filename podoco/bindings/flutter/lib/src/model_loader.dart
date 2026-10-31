import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:podoco/podoco.dart';
import 'package:yaml/yaml.dart';

import 'model_resources.dart';

enum ModelLoadStage { locating, verifying, opening }

class ModelLoadProgress {
  final ModelLoadStage stage;
  final String component;
  const ModelLoadProgress(this.stage, this.component);
}

/// Metadata only; model payload verification still occurs when opening.
class LocatedAnalysisPack {
  final String id, directory;
  final Map<String, String> manifestHashes;
  LocatedAnalysisPack._(this.id, this.directory, Map<String, String> hashes)
    : manifestHashes = Map.unmodifiable(hashes);

  bool get hasFormula => manifestHashes.containsKey('formula');
  bool get hasMath => manifestHashes.containsKey('math');
}

/// Pinned manifest metadata for comparing already-computed results. This is not
/// a verified model bundle and cannot be used to open an analyzer. Payloads are
/// still fully verified by [FlutterModelLoader.verifyLayout] before inference.
class BundledLayoutIdentity {
  const BundledLayoutIdentity._(
    this.pack,
    this.modelId,
    this.profile,
    this.adapter,
    this.backend,
  );
  final LocatedAnalysisPack pack;
  final String modelId, profile, adapter, backend;
  String get manifestSha256 => pack.manifestHashes['layout']!;
}

abstract final class FlutterPodoco {
  static Future<Analyzer> openAnalyzer({
    required BundledAnalysisPack pack,
    required AnalyzerOptions options,
    bool includeFormula = true,
    FormulaOptions? formulaOptions,
    void Function(ModelLoadProgress)? onProgress,
  }) => const FlutterModelLoader().openAnalyzer(
    pack: pack,
    options: options,
    includeFormula: includeFormula,
    formulaOptions: formulaOptions,
    onProgress: onProgress,
  );

  static Future<MathProcessor> openMathProcessor({
    required BundledAnalysisPack pack,
    MathLimits? limits,
    void Function(ModelLoadProgress)? onProgress,
  }) => const FlutterModelLoader().openMathProcessor(
    pack: pack,
    limits: limits,
    onProgress: onProgress,
  );
}

/// Opens immutable app resources directly. It never installs, copies, downloads,
/// recompiles, or substitutes models. Callers own and dispose returned engines.
class FlutterModelLoader {
  final ModelResources resources;
  const FlutterModelLoader({this.resources = const NativeModelResources()});

  Future<LocatedAnalysisPack> locatePack(BundledAnalysisPack pack) async {
    try {
      if (!RegExp(r'^[a-z][a-z0-9_]{0,79}$').hasMatch(pack.package) ||
          !_relative(pack.assetRoot) ||
          !_hash(pack.catalogSha256)) {
        throw _invalid('Invalid bundled pack descriptor');
      }
      final platform = await resources.platformKey();
      if (platform != 'macos-arm64') {
        throw const PodocoException(
          'unsupported_capability',
          'Bundled analysis currently requires macOS on Apple Silicon.',
        );
      }
      final directory = await resources.locateDirectory(pack);
      if (directory == null) {
        throw _invalid(
          'Bundled analysis assets are missing from this application.',
        );
      }
      final root = await Directory(directory).resolveSymbolicLinks();
      final path = '$root${Platform.pathSeparator}pack.json';
      if (await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw _invalid('Pack catalog must be a regular file');
      }
      final file = await File(path).open();
      late List<int> bytes;
      try {
        bytes = await file.read(1024 * 1024 + 1);
      } finally {
        await file.close();
      }
      if (bytes.length > 1024 * 1024 ||
          sha256.convert(bytes).toString() != pack.catalogSha256) {
        throw _invalid(
          'Bundled analysis catalog differs from its pinned identity',
        );
      }
      final catalog = jsonDecode(utf8.decode(bytes));
      if (catalog is! Map<String, dynamic> ||
          catalog['schema_version'] != 1 ||
          catalog['id'] is! String ||
          (catalog['id'] as String).isEmpty ||
          catalog['platforms'] is! List ||
          (catalog['platforms'] as List).any((v) => v is! String) ||
          catalog.keys.toSet().difference({
            'schema_version',
            'id',
            'platforms',
            'layout',
            'formula',
            'math',
          }).isNotEmpty) {
        throw _invalid('Invalid bundled analysis catalog');
      }
      if (!(catalog['platforms'] as List).contains(platform)) {
        throw const PodocoException(
          'unsupported_capability',
          'This application does not include analysis models for this platform.',
        );
      }
      final hashes = <String, String>{};
      for (final kind in ['layout', 'formula', 'math']) {
        final component = catalog[kind];
        if (kind != 'layout' && component == null) continue;
        if (component is! Map ||
            component.length != 2 ||
            component['directory'] != kind ||
            component['manifestSha256'] is! String ||
            !_hash(component['manifestSha256'] as String)) {
          throw _invalid('Invalid $kind component');
        }
        hashes[kind] = component['manifestSha256'] as String;
      }
      return LocatedAnalysisPack._(catalog['id'] as String, root, hashes);
    } on FileSystemException catch (error) {
      throw PodocoException(
        'io',
        'Cannot read bundled analysis assets: ${error.message}',
      );
    } on FormatException {
      throw _invalid('Invalid bundled analysis catalog encoding');
    }
  }

  Future<String> _component(LocatedAnalysisPack pack, String kind) async {
    if (!pack.manifestHashes.containsKey(kind)) {
      throw PodocoException(
        'unsupported_capability',
        'This asset pack has no $kind component.',
      );
    }
    final root = '${pack.directory}${Platform.pathSeparator}$kind';
    try {
      if (await FileSystemEntity.type(root, followLinks: false) !=
          FileSystemEntityType.directory) {
        throw _invalid('Bundled $kind assets are missing or linked');
      }
      await for (final entry in Directory(
        root,
      ).list(recursive: true, followLinks: false)) {
        if (entry is Link || (entry is! File && entry is! Directory)) {
          throw _invalid(
            'Bundled $kind assets must not contain links or special files',
          );
        }
      }
      return root;
    } on FileSystemException catch (error) {
      throw PodocoException(
        'io',
        'Cannot access bundled $kind assets: ${error.message}',
      );
    }
  }

  /// Verify only layout payloads; catalog metadata for other components is
  /// retained without reading or opening their models.
  Future<({LocatedAnalysisPack pack, ModelBundle layout})> verifyLayout({
    required BundledAnalysisPack pack,
    void Function(ModelLoadProgress)? onProgress,
  }) async {
    onProgress?.call(
      const ModelLoadProgress(ModelLoadStage.locating, 'analysis'),
    );
    final located = await locatePack(pack);
    onProgress?.call(
      const ModelLoadProgress(ModelLoadStage.verifying, 'layout'),
    );
    final layout = await ModelBundle.verify(
      await _component(located, 'layout'),
    );
    _identity(located, 'layout', layout.manifestSha256);
    return (pack: located, layout: layout);
  }

  /// Read a bounded, hash-pinned layout manifest without reading model weights.
  /// Suitable only for cache compatibility. Missing or altered catalogs,
  /// manifests and linked/special files still fail closed; missing payloads are
  /// detected when [verifyLayout] is called to open the model.
  Future<BundledLayoutIdentity> readLayoutIdentity(
    BundledAnalysisPack pack,
  ) async {
    final located = await locatePack(pack);
    final root = await _component(located, 'layout');
    final path = '$root${Platform.pathSeparator}podoco-bundle.yaml';
    try {
      if (await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw _invalid('Layout manifest must be a regular file');
      }
      final file = await File(path).open();
      late List<int> bytes;
      try {
        bytes = await file.read(1024 * 1024 + 1);
      } finally {
        await file.close();
      }
      if (bytes.length > 1024 * 1024) {
        throw _invalid('Layout manifest exceeds metadata budget');
      }
      _identity(located, 'layout', sha256.convert(bytes).toString());
      final manifest = loadYaml(utf8.decode(bytes));
      if (manifest is! Map ||
          manifest['schema_version'] != 1 ||
          manifest['profile'] is! Map ||
          manifest['runtime'] is! Map) {
        throw _invalid('Invalid layout identity metadata');
      }
      String field(Object? value) {
        if (value is! String || value.isEmpty || value.length > 256) {
          throw _invalid('Invalid layout identity field');
        }
        return value;
      }

      return BundledLayoutIdentity._(
        located,
        field(manifest['id']),
        field(manifest['profile']['id']),
        field(manifest['profile']['adapter']),
        field(manifest['runtime']['kind']),
      );
    } on FileSystemException catch (error) {
      throw PodocoException(
        'io',
        'Cannot read layout identity: ${error.message}',
      );
    } on YamlException {
      throw _invalid('Invalid layout manifest YAML');
    } on FormatException {
      throw _invalid('Invalid layout manifest encoding');
    }
  }

  Future<Analyzer> openAnalyzer({
    required BundledAnalysisPack pack,
    required AnalyzerOptions options,
    bool includeFormula = true,
    FormulaOptions? formulaOptions,
    void Function(ModelLoadProgress)? onProgress,
  }) async {
    if (!includeFormula && formulaOptions != null) {
      throw ArgumentError('formulaOptions requires includeFormula');
    }
    final verified = await verifyLayout(pack: pack, onProgress: onProgress);
    final located = verified.pack, layout = verified.layout;
    FormulaBundle? formula;
    if (includeFormula && located.hasFormula) {
      onProgress?.call(
        const ModelLoadProgress(ModelLoadStage.verifying, 'formula'),
      );
      formula = await FormulaBundle.verify(
        await _component(located, 'formula'),
      );
      _identity(located, 'formula', formula.manifestSha256);
    }
    onProgress?.call(
      const ModelLoadProgress(ModelLoadStage.opening, 'analysis'),
    );
    final analyzer = await Analyzer.open(
      layout,
      formulaBundle: formula,
      options: options,
      formulaOptions: formulaOptions,
    );
    final expected = [
      layout.manifestSha256,
      if (formula != null) formula.manifestSha256,
    ];
    if (analyzer.modelManifests.length != expected.length ||
        Iterable.generate(expected.length)
            .any((i) => analyzer.modelManifests[i] != expected[i])) {
      await analyzer.dispose();
      throw _invalid('Bundled analysis identity changed while opening');
    }
    return analyzer;
  }

  Future<MathProcessor> openMathProcessor({
    required BundledAnalysisPack pack,
    MathLimits? limits,
    void Function(ModelLoadProgress)? onProgress,
  }) async {
    onProgress?.call(const ModelLoadProgress(ModelLoadStage.locating, 'math'));
    final located = await locatePack(pack);
    onProgress?.call(const ModelLoadProgress(ModelLoadStage.verifying, 'math'));
    final rules = await MathRules.verify(await _component(located, 'math'));
    _identity(located, 'math', rules.manifestSha256);
    onProgress?.call(const ModelLoadProgress(ModelLoadStage.opening, 'math'));
    final processor = await MathProcessor.open(rules, limits: limits);
    if (processor.rulesManifestSha256 != rules.manifestSha256) {
      await processor.dispose();
      throw _invalid('Bundled math identity changed while opening');
    }
    return processor;
  }
}

void _identity(LocatedAnalysisPack pack, String kind, String actual) {
  if (actual != pack.manifestHashes[kind]) {
    throw _invalid('Bundled $kind manifest differs from its pinned identity');
  }
}

bool _hash(String value) => RegExp(r'^[a-f0-9]{64}$').hasMatch(value);
bool _relative(String value) =>
    value.isNotEmpty &&
    value.length <= 4096 &&
    !value.contains(RegExp(r'[\\:\x00]')) &&
    value.split('/').every((p) => p.isNotEmpty && p != '.' && p != '..');
PodocoException _invalid(String message) =>
    PodocoException('invalid_asset', message);
