import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:podoco/podoco.dart' as podoco;
import 'package:podofo_one/src/analysis/analysis_store.dart';
import 'package:podofo_one/src/analysis/preview_layout_store.dart';

import 'fixtures/analysis_fixture.dart';

void main() {
  late Directory root;
  final document = podoco.DocumentRef('preview-store', 'v1');
  final profile = PreviewLayoutProfile(
    layoutManifest: fixtureManifest,
    layoutProfile: fixtureProfile,
    layoutAdapter: 'app-fixture',
    backend: 'test',
    computePolicy: podoco.ComputePolicy.cpuOnly,
    formulaManifest: 'c' * 64,
    combinedProfile: fixtureProfile,
    combinedAdapter: 'app-fixture',
  );
  setUp(() async {
    root = await Directory.systemTemp.createTemp('preview-layout-store-');
  });
  tearDown(() => root.delete(recursive: true));

  test('layout projection retains actual combined provenance without changing richer manual bytes', () async {
    final manual = AnalysisStore(Directory('${root.path}/manual'));
    final previews = PreviewLayoutStore(Directory('${root.path}/preview'));
    final update = formulaFixture(
      document,
      stage: 2,
      formulaManifest: 'c' * 64,
    );
    final key = profile.keys(document).last;
    final full = (await manual.apply(key, update, () => true))!;
    final file =
        (await manual.directory.list().where((f) => f is File).first) as File;
    final before = await file.readAsBytes();
    final projected = (await previews.publish(full, profile, () => true))!;
    expect(projected.complete, false);
    expect(
      projected.page.formulas.single.state,
      isA<podoco.FormulaNotRequested>(),
    );
    expect(projected.projectedFromFormulaScope, podoco.FormulaScope.all);
    expect(projected.page.regions.length, full.page.regions.length);
    expect(
      (projected.toJson()['page'] as Map)['provenance'],
      (full.toJson()['page'] as Map)['provenance'],
    );
    expect(await file.readAsBytes(), before);
    expect((await manual.read(key, 0, document))!.page.formulas, hasLength(1));
    final reopened = PreviewLayoutStore(previews.directory);
    expect(
      (await reopened.readCompatible(document, 0, profile))!.toJson(),
      projected.toJson(),
    );
    expect(previews.maxBytes, 16 * 1024 * 1024);
    expect(previews.maxPageBytes, 4 * 1024 * 1024);
  });

  test(
    'profile, adapter, compute, document and render mismatches do not project',
    () async {
      final previews = PreviewLayoutStore(root);
      final source = AnalysisPageSnapshot.fromUpdate(analysisFixture(document));
      for (final field in ['profile', 'adapter', 'compute_policy']) {
        final json =
            jsonDecode(jsonEncode(source.toJson())) as Map<String, dynamic>;
        json['page']['provenance']['pipeline'][field] =
            field == 'compute_policy' ? 'all' : 'wrong';
        final snapshot = AnalysisPageSnapshot.fromJson(json);
        expect(await previews.publish(snapshot, profile, () => true), isNull);
      }
      final json =
          jsonDecode(jsonEncode(source.toJson())) as Map<String, dynamic>;
      json['page']['provenance']['render_profile'] = 'wrong';
      expect(
        await previews.publish(
          AnalysisPageSnapshot.fromJson(json),
          profile,
          () => true,
        ),
        isNull,
      );
      await previews.publish(source, profile, () => true);
      expect(
        await previews.readCompatible(
          podoco.DocumentRef('preview-store', 'v2'),
          0,
          profile,
        ),
        isNull,
      );
      expect(await previews.publish(source, profile, () => false), isNull);
    },
  );

  test('per-page rejection, bounded pruning and corrupt cache leave manual data alone', () async {
    final sample = AnalysisPageSnapshot.fromUpdate(analysisFixture(document));
    final small = PreviewLayoutStore(
      Directory('${root.path}/small'),
      maxPageBytes: 1,
    );
    await expectLater(
      small.publish(sample, profile, () => true),
      throwsStateError,
    );
    final store = PreviewLayoutStore(
      Directory('${root.path}/bounded'),
      maxBytes: 2500,
    );
    for (var i = 0; i < 8; i++) {
      await store.publish(
        AnalysisPageSnapshot.fromUpdate(
          analysisFixture(document, pageIndex: i),
        ),
        profile,
        () => true,
      );
    }
    final files = await store.directory
        .list()
        .where((f) => f is File)
        .cast<File>()
        .toList();
    var bytes = 0;
    for (final file in files) {
      bytes += await file.length();
    }
    expect(bytes, lessThanOrEqualTo(2500));
    expect(files.length, lessThan(8));
    expect(await store.readCompatible(document, 0, profile), isNull);
    await files.last.writeAsString('{broken');
    final index = int.parse(files.last.path.split('-').last.split('.').first);
    expect(await store.readCompatible(document, index, profile), isNull);
  });
}
