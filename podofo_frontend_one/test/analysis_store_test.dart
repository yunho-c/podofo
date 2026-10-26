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
    key = analysisCacheKey(
      document,
      [fixtureManifest],
      fixtureProfile,
      podoco.ComputePolicy.cpuOnly,
    );
  });
  tearDown(() => directory.delete(recursive: true));

  test('formula updates persist progressively without changing SDK event contracts', () async {
    await store.write(key, formulaFixture(document), () => true);
    final update = formulaFixture(document, stage: 1);
    final partial = await store.apply(key, update, () => true);
    expect(partial!.complete, false);
    expect(
      partial.page.formulas.single.state,
      isA<podoco.FormulaFinishedState>(),
    );
    final formula =
        (partial.page.formulas.single.state as podoco.FormulaFinishedState)
                .outcome
            as podoco.FormulaRecognized;
    expect(formula.formula.latex, r'\frac{x+1}{2}');
    expect(
      (await AnalysisStore(directory).read(key, 0, document))!.toJson(),
      partial.toJson(),
    );
    expect(
      await store.apply(key, update, () => true),
      isNull,
    ); // Duplicate sequence.
    await expectLater(
      store.apply(
        key,
        formulaFixture(document, stage: 1, analysisId: 'wrong-job'),
        () => true,
      ),
      throwsStateError,
    );
    await store.write(key, formulaFixture(document, stage: 2), () => true);
    expect((await store.read(key, 0, document))!.complete, true);
  });

  test(
    'cache identity includes every ordered model, compute policy and profile',
    () async {
      final second = 'c' * 64;
      final combined = analysisCacheKey(
        document,
        [fixtureManifest, second],
        fixtureProfile,
        podoco.ComputePolicy.cpuOnly,
      );
      expect(combined, isNot(key));
      expect(
        analysisCacheKey(
          document,
          [second, fixtureManifest],
          fixtureProfile,
          podoco.ComputePolicy.cpuOnly,
        ),
        isNot(combined),
      );
      expect(
        analysisCacheKey(
          document,
          [fixtureManifest, second],
          fixtureProfile,
          podoco.ComputePolicy.cpuAndNeuralEngine,
        ),
        isNot(combined),
      );
      await store.write(
        combined,
        formulaFixture(document, formulaManifest: second),
        () => true,
      );
      expect(await store.read(combined, 0, document), isNotNull);
      await expectLater(
        store.write(
          key,
          formulaFixture(document, formulaManifest: second),
          () => true,
        ),
        throwsStateError,
      );
    },
  );

  test('progressive and authoritative pages survive reopen without mixing revisions', () async {
    final initial = analysisFixture(document);
    expect(await store.write(key, initial, () => true), true);
    final reopened = AnalysisStore(directory);
    expect(
      await reopened.read(key, 0, document),
      isA<AnalysisPageSnapshot>().having((s) => s.complete, 'complete', false),
    );
    final finalPage = analysisFixture(document, finished: true);
    await store.write(key, finalPage, () => true);
    expect(
      await reopened.read(key, 0, document),
      isA<AnalysisPageSnapshot>().having((s) => s.complete, 'complete', true),
    );
    expect(
      await reopened.read(key, 0, podoco.DocumentRef('test', 'new')),
      isNull,
    );
    expect(
      analysisCacheKey(
        document,
        ['b' * 64],
        fixtureProfile,
        podoco.ComputePolicy.cpuOnly,
      ),
      isNot(key),
    );
    expect(
      analysisCacheKey(
        document,
        [fixtureManifest],
        'different',
        podoco.ComputePolicy.cpuOnly,
      ),
      isNot(key),
    );
  });
  test('generation is checked again after asynchronous staging', () async {
    final previous = analysisFixture(document, finished: true);
    await store.write(key, previous, () => true);
    var guards = 0;
    expect(
      await store.write(
        key,
        analysisFixture(document, analysisId: 'next-job'),
        () => ++guards == 1,
      ),
      false,
    );
    expect(guards, 2);
    expect(
      await store.read(key, 0, document),
      isA<AnalysisPageSnapshot>().having((s) => s.complete, 'complete', true),
    );
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
