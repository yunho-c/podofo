import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:podoco/podoco.dart';
import 'package:podoco_flutter/podoco_flutter.dart';

class Resources implements ModelResources {
  String platform = 'macos-arm64';
  String? root;
  int locations = 0;
  @override
  Future<String> platformKey() async => platform;
  @override
  Future<String?> locateDirectory(BundledAnalysisPack pack) async {
    locations++;
    return root;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late Resources resources;
  late FlutterModelLoader loader;
  final hash = List.filled(64, 'a').join();
  Map<String, Object?> catalog() => {
    'schema_version': 1,
    'id': 'test-pack-v1',
    'platforms': ['macos-arm64'],
    'layout': {'directory': 'layout', 'manifestSha256': hash},
    'formula': {'directory': 'formula', 'manifestSha256': hash},
    'math': null,
  };
  Future<BundledAnalysisPack> pack([Map<String, Object?>? value]) async {
    final bytes = utf8.encode(jsonEncode(value ?? catalog()));
    await File('${directory.path}/pack.json').writeAsBytes(bytes);
    return BundledAnalysisPack(
      package: 'test_assets',
      assetRoot: 'models',
      catalogSha256: sha256.convert(bytes).toString(),
    );
  }

  Matcher code(String name) =>
      isA<PodocoException>().having((e) => e.code, 'code', name);
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('podoco-resources-');
    resources = Resources()..root = directory.path;
    loader = FlutterModelLoader(resources: resources);
  });
  tearDown(() => directory.delete(recursive: true));

  const identityYaml = '''
schema_version: 1
id: fixture-layout
runtime: {kind: coreml}
profile: {id: fixture-profile, adapter: fixture-adapter}
''';
  Future<BundledAnalysisPack> identityPack([String yaml = identityYaml]) async {
    await Directory('${directory.path}/layout').create(recursive: true);
    await File('${directory.path}/layout/podoco-bundle.yaml')
        .writeAsString(yaml);
    return pack(
      catalog()
        ..['layout'] = {
          'directory': 'layout',
          'manifestSha256': sha256.convert(utf8.encode(yaml)).toString(),
        },
    );
  }

  test('cache identity verifies pinned metadata without requiring model or formula payloads', () async {
    final selection = await identityPack();
    final identity = await loader.readLayoutIdentity(selection);
    expect(identity.modelId, 'fixture-layout');
    expect(identity.profile, 'fixture-profile');
    expect(identity.adapter, 'fixture-adapter');
    expect(identity.backend, 'coreml');
    expect(
      identity.manifestSha256,
      sha256.convert(utf8.encode(identityYaml)).toString(),
    );
    expect(identity.pack.hasFormula, true);
    expect(await Directory('${directory.path}/formula').exists(), false);
    // Returning metadata cannot be mistaken for a ModelBundle accepted by open.
    expect(identity, isNot(isA<ModelBundle>()));
    directory = await directory.rename('${directory.path}-relocated');
    resources.root = directory.path;
    expect(
      (await loader.readLayoutIdentity(selection)).manifestSha256,
      identity.manifestSha256,
    );
  });
  test(
    'altered or absent layout identity cannot reuse the pinned catalog',
    () async {
      final selection = await identityPack();
      final manifest = File('${directory.path}/layout/podoco-bundle.yaml');
      await manifest.writeAsString(
        identityYaml.replaceFirst('fixture-layout', 'different-model'),
      );
      await expectLater(
        loader.readLayoutIdentity(selection),
        throwsA(code('invalid_asset')),
      );
      await manifest.delete();
      await expectLater(
        loader.readLayoutIdentity(selection),
        throwsA(code('invalid_asset')),
      );
    },
  );
  test('pinned malformed or oversized identity metadata is rejected', () async {
    for (final yaml in [
      '[malformed',
      'schema_version: 2',
      identityYaml.replaceFirst('id: fixture-layout', 'id: []'),
      identityYaml.replaceFirst('id: fixture-profile', 'id: null'),
      identityYaml.replaceFirst('adapter: fixture-adapter', 'adapter: 4'),
      'x' * (1024 * 1024 + 1),
    ]) {
      await expectLater(
        loader.readLayoutIdentity(await identityPack(yaml)),
        throwsA(code('invalid_asset')),
      );
    }
  });
  test('metadata read preserves platform, catalog and link checks', () async {
    final selection = await identityPack();
    resources.platform = 'linux-x64';
    await expectLater(
      loader.readLayoutIdentity(selection),
      throwsA(code('unsupported_capability')),
    );
    expect(resources.locations, 0);
    resources.platform = 'macos-arm64';
    final manifest = File('${directory.path}/layout/podoco-bundle.yaml');
    final original = await manifest.rename('${directory.path}/original.yaml');
    await Link(manifest.path).create(original.path);
    await expectLater(
      loader.readLayoutIdentity(selection),
      throwsA(code('invalid_asset')),
    );
    await Link(manifest.path).delete();
    await original.rename(manifest.path);
    await File('${directory.path}/pack.json').writeAsString('{}');
    await expectLater(
      loader.readLayoutIdentity(selection),
      throwsA(code('invalid_asset')),
    );
  }, skip: Platform.isWindows);

  test(
    'catalog pins survive relocation and expose immutable metadata',
    () async {
      final selection = await pack();
      final first = await loader.locatePack(selection);
      expect(first.id, 'test-pack-v1');
      expect(first.hasFormula, isTrue);
      expect(first.hasMath, isFalse);
      expect(
        () => first.manifestHashes['layout'] = 'changed',
        throwsUnsupportedError,
      );
      directory = await directory.rename('${directory.path}-relocated');
      resources.root = directory.path;
      final relocated = await loader.locatePack(selection);
      expect(relocated.manifestHashes, first.manifestHashes);
      expect(relocated.directory, await directory.resolveSymbolicLinks());
    },
  );
  test('unsupported platform does not look for assets', () async {
    resources.platform = 'windows-x64';
    await expectLater(
      loader.locatePack(await pack()),
      throwsA(code('unsupported_capability')),
    );
    expect(resources.locations, 0);
  });
  test(
    'layout-only opening rejects formula options before locating any assets',
    () async {
      final selection = await pack();
      await expectLater(
        loader.openAnalyzer(
          pack: selection,
          includeFormula: false,
          formulaOptions: FormulaOptions(),
          options: AnalyzerOptions(
            computePolicy: ComputePolicy.cpuOnly,
            limits: ResourceLimits(
              queuedJobs: 1,
              inputBytes: 4,
              pendingUpdates: 1,
              resultBytes: 1024,
              maxUpdateBytes: 1024,
              tensorBytes: 1024,
              decoderCacheBytes: 1,
            ),
          ),
        ),
        throwsArgumentError,
      );
      expect(resources.locations, 0);
    },
  );
  test('missing and changed catalogs fail without fallback', () async {
    final selection = await pack();
    resources.root = null;
    await expectLater(
      loader.locatePack(selection),
      throwsA(code('invalid_asset')),
    );
    resources.root = directory.path;
    await File('${directory.path}/pack.json').writeAsString('{}');
    await expectLater(
      loader.locatePack(selection),
      throwsA(code('invalid_asset')),
    );
  });
  test(
    'malformed descriptors and escaped component paths are rejected',
    () async {
      for (final root in [
        '',
        '../models',
        '/models',
        'models//x',
        r'models\x',
      ]) {
        await expectLater(
          loader.locatePack(
            BundledAnalysisPack(
              package: 'test_assets',
              assetRoot: root,
              catalogSha256: hash,
            ),
          ),
          throwsA(code('invalid_asset')),
        );
      }
      expect(resources.locations, 0);
      final bad = catalog()
        ..['layout'] = {'directory': '../escape', 'manifestSha256': hash};
      await expectLater(
        loader.locatePack(await pack(bad)),
        throwsA(code('invalid_asset')),
      );
    },
  );
  test('absent math is independent of available analysis metadata', () async {
    final selection = await pack();
    expect((await loader.locatePack(selection)).hasFormula, isTrue);
    final stages = <ModelLoadStage>[];
    await expectLater(
      loader.openMathProcessor(
        pack: selection,
        onProgress: (p) => stages.add(p.stage),
      ),
      throwsA(code('unsupported_capability')),
    );
    expect(stages, [ModelLoadStage.locating, ModelLoadStage.verifying]);
  });
  test('linked catalogs and linked component files are rejected', () async {
    final data = catalog()
      ..['math'] = {'directory': 'math', 'manifestSha256': hash};
    final selection = await pack(data);
    await Directory('${directory.path}/math').create();
    await Link('${directory.path}/math/outside')
        .create('${directory.path}/pack.json');
    await expectLater(
      loader.openMathProcessor(pack: selection),
      throwsA(code('invalid_asset')),
    );
    await File('${directory.path}/pack.json')
        .rename('${directory.path}/real.json');
    await Link('${directory.path}/pack.json')
        .create('${directory.path}/real.json');
    await expectLater(
      loader.locatePack(selection),
      throwsA(code('invalid_asset')),
    );
  }, skip: Platform.isWindows);
  test(
    'native channel reports missing plugin and preserves platform errors',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(NativeModelResources.channel, null);
      await expectLater(
        const NativeModelResources().platformKey(),
        throwsA(code('unsupported_capability')),
      );
      messenger.setMockMethodCallHandler(NativeModelResources.channel, (
        _,
      ) async {
        throw PlatformException(code: 'invalid_asset', message: 'broken pack');
      });
      try {
        await expectLater(
          const NativeModelResources().platformKey(),
          throwsA(code('invalid_asset')),
        );
      } finally {
        messenger.setMockMethodCallHandler(NativeModelResources.channel, null);
      }
    },
  );
}
