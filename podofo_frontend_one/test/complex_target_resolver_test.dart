import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:podofo_one/src/analysis/preview_layout_repository.dart';
import 'package:podofo_one/src/analysis/analysis_snapshot.dart';
import 'package:podofo_one/src/previews/link_target.dart';
import 'package:podofo_one/src/previews/link_target_resolver.dart';
import 'package:podofo_one/src/previews/pdf_link_context.dart';
import 'package:podofo_one/src/services/pdf_session.dart';
import 'package:podofo_one/src/workers/link_preview_worker.dart';

import 'support/complex_preview_fixture.dart';
import 'support/file_access_mock.dart';
import 'support/target_preview_metrics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fixture = ComplexPreviewFixture();
  late Directory temp;
  late PdfSession session;
  late Directory artifacts;
  setUpAll(() async {
    installFileAccessMock();
    temp = await Directory.systemTemp.createTemp('complex-target-');
    await pdfrxInitialize(tmpPath: temp.path);
    session = await PdfSession.open(
      'test/fixtures/target_preview/complex_objects.pdf',
    );
    artifacts = await Directory('build/target-preview-m4/resolved')
        .create(recursive: true);
  });
  tearDownAll(() async {
    await session.close();
    await PdfrxEntryFunctions.instance.stopBackgroundWorker();
    await temp.delete(recursive: true);
  });
  for (final c in fixture.cases) {
    test(
      '${c['id']}: complete target or conservative fallback from native text',
      () async {
        final context = PdfLinkContext();
        final repository = _Repository(fixture, session);
        final request = await fixture.request(session, c['id']);
        try {
          final prepared = (await context.prepare(
            request,
            () => true,
            repository,
          ))!;
          final result = prepared.resolution;
          final expectedPage = c['destination']['page'] as int;
          expect(repository.pages, [
            expectedPage,
            if (c['id'] == 'cross-page' || c['id'] == 'unfinished-entry')
              expectedPage + 1,
          ]);
          if (c['kind'] == null) {
            expect(
              result.tier,
              LinkTargetTier.unresolved,
              reason: result.reason,
            );
            expect(result.parts, isEmpty);
            return;
          }
          expect(result.kind?.name, c['kind'], reason: result.reason);
          expect(
            result.tier,
            LinkTargetTier.matchedIdentity,
            reason: result.reason,
          );
          expect(result.parts.length, lessThanOrEqualTo(4));
          final pages = result.parts.map((p) => p.page).toSet();
          expect(pages.length, c['id'] == 'cross-page' ? 2 : 1);
          final metrics = <Map<String, Object>>[];
          for (final number in pages) {
            final value = await previewPixelMetrics(
              session.lease.document.pages[number - 1],
              result.parts
                  .where((p) => p.page == number)
                  .map((p) => p.bounds)
                  .toList(),
              (c['required_parts'] as List)
                  .where((p) => p['page'] == number)
                  .map((p) => previewFixtureRect(p['bounds']))
                  .toList(),
              (c['excluded_neighbors'] as List)
                  .where((p) => p['page'] == number)
                  .map((p) => previewFixtureRect(p['bounds']))
                  .toList(),
            );
            metrics.add({'page': number, ...value});
            for (final m in value['required'] as List) {
              expect(m['ink'], greaterThan(0));
              expect(
                (m['covered'] as int) / (m['ink'] as int),
                greaterThanOrEqualTo(.995),
                reason: '${c['id']} $m',
              );
            }
            for (final m in value['excluded'] as List) {
              expect(m['covered'], 0, reason: '${c['id']} $m');
            }
          }
          for (final size in [semanticPreviewMaxSize, const Size(163, 211)]) {
            final image = (await session.readLocked(
              (pdf) => renderResolvedLinkPreview(
                pdf,
                result,
                2,
                LinkPreviewCancellation(),
                maxSize: size,
              ),
            ))!;
            try {
              final png = (await image.toByteData(
                format: ImageByteFormat.png,
              ))!;
              await File(
                '${artifacts.path}/${c['id']}-${size.width.toInt()}.png',
              ).writeAsBytes(png.buffer.asUint8List());
            } finally {
              image.dispose();
            }
          }
          await File('${artifacts.path}/${c['id']}.json').writeAsString(
            const JsonEncoder.withIndent('  ').convert({
              'kind': result.kind!.name,
              'reason': result.reason,
              'evidence': result.evidenceIdentity.toString(),
              'parts': result.parts
                  .map(
                    (p) => {
                      'page': p.page,
                      'bounds': [
                        p.bounds.left,
                        p.bounds.top,
                        p.bounds.right,
                        p.bounds.bottom,
                      ],
                    },
                  )
                  .toList(),
              'metrics': metrics,
              'layout_source': fixture.manifest['layout_source'],
            }),
          );
          expect(session.revision, 0);
          expect(session.navigationHistory.previous, isNull);
        } finally {
          context.clear();
        }
      },
    );
  }

  test('only matched last-entry evidence requests continuation, and missing evidence never resolves a prefix', () async {
    final context = PdfLinkContext();
    try {
      final request = await fixture.request(session, 'cross-page');
      final p = (await context.prepare(request, () => true, null))!;
      final resolver = const LinkTargetResolver();
      final first = PreviewLayoutEvidence(fixture.snapshot(session, 4));
      final unresolved = resolver.resolve(
        p.destination,
        source: p.source,
        text: p.targetText,
        layout: first,
      );
      expect(unresolved.tier, LinkTargetTier.unresolved);
      expect(unresolved.continuationPage, 5);
      expect(unresolved.parts, isEmpty);
      final repository = _Repository(fixture, session)..missing = 5;
      final missing = (await context.prepare(
        request,
        () => true,
        repository,
      ))!.resolution;
      expect(missing.tier, LinkTargetTier.unresolved);
      expect(missing.parts, isEmpty);
      expect(repository.pages, [4, 5]);
      final wrong = resolver.resolve(
        p.destination,
        source: p.source,
        text: p.targetText,
        layout: first,
        followingText: (await context.text(request, 6, () => true))!,
        followingLayout: PreviewLayoutEvidence(fixture.snapshot(session, 6)),
      );
      expect(wrong.reason, 'invalidContinuationPage');
    } finally {
      context.clear();
    }
  });

  test('year-only and bracket-only annotations retain identity; distinct years and suffixes do not alias', () async {
    final context = PdfLinkContext();
    try {
      final request = await fixture.request(session, 'author-hanging');
      final p = (await context.prepare(request, () => true, null))!;
      final evidence = PreviewLayoutEvidence(fixture.snapshot(session, 2));
      LinkSourceText source(String selected, String before, String after) =>
          LinkSourceText(
            [PreviewTextSpan(0, selected.length, selected, [])],
            before,
            after,
            false,
          );
      for (final selected in [
        'Rivera et al. (2024)',
        '2024',
        '2024a',
        '2025',
        'Park (2024)',
      ]) {
        final target = const LinkTargetResolver().resolve(
          p.destination,
          source: source(selected, 'See Rivera et al. (', ')'),
          text: p.targetText,
          layout: evidence,
        );

        expect(
          target.tier,
          selected == '2024' || selected == 'Rivera et al. (2024)'
              ? LinkTargetTier.matchedIdentity
              : LinkTargetTier.unresolved,
          reason: selected,
        );
      }
      final numeric = const LinkTargetResolver().resolve(
        const PreviewDestination(
          page: 2,
          pageSize: Size(612, 792),
          x: 36,
          y: 78,
        ),
        source: source('31', 'See [', ']'),
        text: p.targetText,
        layout: evidence,
      );
      expect(numeric.label, 'Reference [31]');
      final listMember = const LinkTargetResolver().resolve(
        p.destination,
        source: source('31', 'See [30, ', ']'),
        text: p.targetText,
        layout: evidence,
      );
      expect(listMember.label, 'Reference [31]');
      final ambiguous = const LinkTargetResolver().resolve(
        p.destination,
        source: source('30, 31', 'See [', ']'),
        text: p.targetText,
        layout: evidence,
      );
      expect(ambiguous.tier, LinkTargetTier.unresolved);
    } finally {
      context.clear();
    }
  });

  test('missing continuation regions never turn a column/page prefix into a complete entry', () async {
    final context = PdfLinkContext();
    PreviewLayoutEvidence without(int page, int id) {
      final json = jsonDecode(
        jsonEncode(fixture.snapshot(session, page).toJson()),
      );
      (json['page']['regions'] as List).removeWhere((r) => r['id'] == id);
      return PreviewLayoutEvidence(
        AnalysisPageSnapshot.fromJson(Map<String, Object?>.from(json)),
      );
    }

    try {
      final columnRequest = await fixture.request(session, 'cross-column');
      final column = (await context.prepare(columnRequest, () => true, null))!;
      final clippedColumn = const LinkTargetResolver().resolve(
        column.destination,
        source: column.source,
        text: column.targetText,
        layout: without(3, 3),
      );
      expect(clippedColumn.tier, LinkTargetTier.unresolved);
      expect(clippedColumn.parts, isEmpty);
      final pageRequest = await fixture.request(session, 'cross-page');
      final page = (await context.prepare(pageRequest, () => true, null))!;
      final nextText = (await context.text(pageRequest, 5, () => true))!;
      final clippedPage = const LinkTargetResolver().resolve(
        page.destination,
        source: page.source,
        text: page.targetText,
        layout: PreviewLayoutEvidence(fixture.snapshot(session, 4)),
        followingText: nextText,
        followingLayout: without(5, 1),
      );
      expect(clippedPage.tier, LinkTargetTier.unresolved);
      expect(clippedPage.parts, isEmpty);
      final wrongFont = PreviewTextPage(nextText.snapshot, [
        for (final box in nextText.boxes)
          box.isEmpty
              ? box
              : Rect.fromCenter(
                  center: box.center,
                  width: box.width,
                  height: box.height * 3,
                ),
      ]);
      final mismatch = const LinkTargetResolver().resolve(
        page.destination,
        source: page.source,
        text: page.targetText,
        layout: PreviewLayoutEvidence(fixture.snapshot(session, 4)),
        followingText: wrongFont,
        followingLayout: PreviewLayoutEvidence(fixture.snapshot(session, 5)),
      );
      expect(mismatch.tier, LinkTargetTier.unresolved);
      expect(mismatch.reason, 'referenceFontMismatch');
    } finally {
      context.clear();
    }
  });

  for (final action in ['cancel', 'edit', 'close']) {
    test(
      '$action during next-page evidence read detaches without holding the PDF lock',
      () async {
        final s = await PdfSession.open(
          'test/fixtures/target_preview/complex_objects.pdf',
        );
        final context = PdfLinkContext();
        final repository = _Repository(fixture, s)..gatePage = 5;
        final cancellation = PreviewCancellation();
        try {
          final request = await fixture.request(s, 'cross-page');
          final future = context.prepare(
            request,
            () => true,
            repository,
            cancellation: cancellation,
          );
          await repository.started.future.timeout(const Duration(seconds: 3));
          if (action == 'close') {
            await s.close().timeout(const Duration(seconds: 3));
          } else if (action == 'edit') {
            s.revision++;
          } else {
            cancellation.cancel();
          }
          repository.release.complete();
          expect(await future, isNull);
          expect(repository.pages, [4, 5]);
        } finally {
          if (!repository.release.isCompleted) repository.release.complete();
          context.clear();
          if (!s.lease.isClosed) await s.close();
        }
      },
    );
  }
}

class _Repository implements PreviewLayoutRepository {
  _Repository(this.fixture, this.session);
  final ComplexPreviewFixture fixture;
  final PdfSession session;
  final pages = <int>[];
  final started = Completer<void>(), release = Completer<void>();
  int? missing, gatePage;
  @override
  Future<PreviewLayoutEvidence?> read(
    LinkPreviewRequest request, {
    required bool Function() isCurrent,
    PreviewCancellation? cancellation,
  }) async {
    final page = request.destination.pageNumber;
    pages.add(page);
    if (page == gatePage) {
      started.complete();
      await release.future;
    }
    return page == missing ||
            !request.isCurrent ||
            !isCurrent() ||
            cancellation?.isCancelled == true
        ? null
        : PreviewLayoutEvidence(fixture.snapshot(session, page));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
