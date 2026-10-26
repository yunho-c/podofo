import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:podoco/podoco.dart' as podoco;
import 'package:podofo_one/src/analysis/analysis_store.dart';

import 'fixtures/analysis_fixture.dart';

void main() {
  late Directory directory;
  late AnalysisStore store;
  final document = podoco.DocumentRef('test', 'revision');
  late String key;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('podoco-store-test-');
    store = AnalysisStore(directory, maxBytes: 5000);
    key = analysisCacheKey(document, fixtureManifest, fixtureProfile);
  });
  tearDown(() => directory.delete(recursive: true));

  test('progressive and authoritative pages survive reopen without mixing revisions', () async {
    final initial = analysisFixture(document);
    expect(await store.write(key, initial, () => true), true);
    final reopened = AnalysisStore(directory);
    expect(
      await reopened.read(key, 0, document),
      isA<podoco.PageLayoutReady>(),
    );
    final finalPage = analysisFixture(document, finished: true);
    await store.write(key, finalPage, () => true);
    expect(await reopened.read(key, 0, document), isA<podoco.PageFinished>());
    expect(
      await reopened.read(key, 0, podoco.DocumentRef('test', 'new')),
      isNull,
    );
    expect(analysisCacheKey(document, 'b' * 64, fixtureProfile), isNot(key));
    expect(
      analysisCacheKey(document, fixtureManifest, 'different'),
      isNot(key),
    );
  });
  test('generation is checked again after asynchronous staging', () async {
    final previous = analysisFixture(document, finished: true);
    await store.write(key, previous, () => true);
    var guards = 0;
    expect(
      await store.write(key, analysisFixture(document), () => ++guards == 1),
      false,
    );
    expect(guards, 2);
    expect(await store.read(key, 0, document), isA<podoco.PageFinished>());
    expect(directory.listSync().whereType<Directory>(), isEmpty);
  });
  test('cache size is bounded and corrupted data is ignored', () async {
    for (var i = 0; i < 12; i++) {
      await store.write(
        key,
        analysisFixture(document, pageIndex: i),
        () => true,
      );
    }
    final files = directory.listSync().whereType<File>();
    expect(
      files.fold<int>(0, (sum, f) => sum + f.lengthSync()),
      lessThanOrEqualTo(5000),
    );
    expect(await store.read(key, 0, document), isNull);
    final newest = File('${directory.path}/$key-11.json');
    await newest.writeAsString('{broken');
    expect(await store.read(key, 11, document), isNull);
  });
}
