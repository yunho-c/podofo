import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:podoco/podoco.dart' as podoco;
import 'package:podofo_one/src/analysis/analysis_store.dart';
import 'package:podofo_one/src/analysis/pdf_analysis_source.dart';
import 'package:podofo_one/src/analysis/preview_layout_repository.dart';
import 'package:podofo_one/src/previews/link_target.dart';
import 'package:podofo_one/src/previews/link_target_resolver.dart';
import 'package:podofo_one/src/previews/pdf_link_context.dart';
import 'package:podofo_one/src/services/pdf_session.dart';
import 'package:podofo_one/src/workers/link_preview_worker.dart';

import 'support/target_preview_metrics.dart';
import 'support/file_access_mock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late PdfSession session;
  late List<PdfLink> links;
  late List<dynamic> cases;
  final context = PdfLinkContext();
  setUpAll(() async {
    installFileAccessMock();
    temp = await Directory.systemTemp.createTemp('preview-resolver-');
    await pdfrxInitialize(tmpPath: temp.path);
    final fixture = 'test/fixtures/target_preview/linked_objects';
    cases = jsonDecode(File('$fixture.json').readAsStringSync())['cases'];
    session = await PdfSession.open('$fixture.pdf');
    links = await session.lease.document.pages.first.loadLinks();
  });
  tearDownAll(() async {
    context.clear();
    await session.close();
    await PdfrxEntryFunctions.instance.stopBackgroundWorker();
    await temp.delete(recursive: true);
  });
  AnalysisPageSnapshot snapshot(int page) => AnalysisPageSnapshot.fromJson(
    Map<String, Object?>.from(
      jsonDecode(
        File(
          'test/fixtures/target_preview/layout/linked_objects-page-$page.json',
        ).readAsStringSync(),
      )['snapshot'],
    ),
  );
  PreviewLayoutEvidence layout(int page) =>
      PreviewLayoutEvidence(snapshot(page));
  Future<PreparedLinkPreview> prepare(int i) async => (await context.prepare(
    LinkPreviewRequest(
      session: session,
      sourcePage: 1,
      annotationIndex: i,
      sourceRects: links[i].rects,
      destination: links[i].dest!,
      pixelRatio: 1,
    ),
    () => true,
    null,
  ))!;
  for (var index = 0; index < 6; index++) {
    test(
      'complete target $index includes required ink and excludes its neighbors',
      () async {
        final c = cases[index], p = await prepare(index);
        final target = const LinkTargetResolver().resolve(
          p.destination,
          source: p.source,
          text: p.targetText,
          layout: layout(links[index].dest!.pageNumber),
        );
        expect(target.kind!.name, c['kind']);
        expect(target.tier, LinkTargetTier.matchedIdentity);
        final metrics = await previewPixelMetrics(
          session.lease.document.pages[target.parts.single.page - 1],
          target.parts.map((p) => p.bounds).toList(),
          (c['required_parts'] as List).map(previewFixtureRect).toList(),
          (c['excluded_neighbors'] as List).map(previewFixtureRect).toList(),
        );
        for (final m in metrics['required'] as List) {
          expect(m['ink'], greaterThan(0));
          expect(
            (m['covered'] as int) / (m['ink'] as int),
            greaterThanOrEqualTo(.995),
            reason: c['id'],
          );
        }
        for (final m in metrics['excluded'] as List) {
          expect(m['covered'], 0, reason: c['id']);
        }
        final image = (await session.readLocked(
          (pdf) => renderResolvedLinkPreview(
            pdf,
            target,
            2,
            LinkPreviewCancellation(),
          ),
        ))!;
        try {
          expect(image.width, lessThanOrEqualTo(720));
          expect(image.height, lessThanOrEqualTo(480));
        } finally {
          image.dispose();
        }
      },
    );
  }
  test('missing text, missing layout, multiple labels and truncated source abstain', () async {
    final p = await prepare(2), evidence = layout(2);
    final resolver = const LinkTargetResolver();
    expect(
      resolver
          .resolve(p.destination, source: p.source, text: p.targetText)
          .tier,
      LinkTargetTier.unresolved,
    );
    expect(
      resolver.resolve(p.destination, source: p.source, layout: evidence).tier,
      LinkTargetTier.unresolved,
    );
    for (final source in [
      LinkSourceText(
        [PreviewTextSpan(0, 21, 'Figure 4 and Figure 5', [])],
        '',
        '',
        false,
      ),
      LinkSourceText(
        [PreviewTextSpan(0, 14, 'Figure 4 and 5', [])],
        '',
        '',
        false,
      ),
      LinkSourceText(p.source!.spans, '', '', true),
      LinkSourceText([PreviewTextSpan(0, 2, '99', [])], '', '', false),
    ]) {
      expect(
        resolver
            .resolve(
              p.destination,
              source: source,
              text: p.targetText,
              layout: evidence,
            )
            .tier,
        LinkTargetTier.unresolved,
      );
    }
  });
  test(
    'section identity does not confuse a parent with a numbered subsection',
    () async {
      final p = await prepare(5);
      final target = const LinkTargetResolver().resolve(
        p.destination,
        source: LinkSourceText(
          [PreviewTextSpan(0, 9, 'Section 2', [])],
          '',
          '',
          false,
        ),
        text: p.targetText,
        layout: layout(2),
      );
      expect(target.tier, LinkTargetTier.unresolved);
    },
  );

  test('page-only destination accepts unique source identity; unknown axes stay unknown', () async {
    final p = await prepare(2);
    final target = const LinkTargetResolver().resolve(
      const PreviewDestination(page: 2, pageSize: Size(612, 792)),
      source: p.source,
      text: p.targetText,
      layout: layout(2),
    );
    expect(target.kind, LinkTargetKind.figure);
    expect(target.label, 'Figure 4');
  });

  test('worker refines after context, reuses semantic raster and transfers ownership', () async {
    final worker = LinkPreviewWorker();
    final store = _SnapshotStore(temp, snapshot(2));
    final request = LinkPreviewRequest(
      session: session,
      sourcePage: 1,
      annotationIndex: 2,
      sourceRects: links[2].rects,
      destination: links[2].dest!,
      pixelRatio: 1,
    );
    final repository = PreviewLayoutRepository(store, _identity(session));
    final images = <Image>[];
    try {
      for (var i = 0; i < 2; i++) {
        var contextDelivered = false;
        final refined = Completer<void>();
        final baseline = await worker.load(
          session,
          links[2].dest!,
          pixelRatio: 1,
          request: request,
          repository: repository,
          onRefinement: (image, target) {
            expect(contextDelivered, true);
            expect(target.label, 'Figure 4');
            expect(target.tier, LinkTargetTier.matchedIdentity);
            images.add(image);
            refined.complete();
          },
        );
        expect(baseline, isNotNull);
        contextDelivered = true;
        baseline!.dispose();
        await refined.future;
        expect(worker.cache.length, 2);
      }
      expect(images[0].isCloneOf(images[1]), true);
      worker.reset();
      expect(worker.cache.bytes, 0);
      for (final image in images) {
        expect(image.debugDisposed, false);
        expect(await image.toByteData(), isNotNull);
      }
    } finally {
      for (final image in images) {
        image.dispose();
      }
      worker.dispose();
    }
  });

  test('reset from refinement callback cannot repopulate the cache', () async {
    final worker = LinkPreviewWorker();
    final refined = Completer<void>();
    try {
      final baseline = await worker.load(
        session,
        links[2].dest!,
        pixelRatio: 1,
        request: LinkPreviewRequest(
          session: session,
          sourcePage: 1,
          annotationIndex: 2,
          sourceRects: links[2].rects,
          destination: links[2].dest!,
          pixelRatio: 1,
        ),
        repository: PreviewLayoutRepository(
          _SnapshotStore(temp, snapshot(2)),
          _identity(session),
        ),
        onRefinement: (image, target) {
          worker.reset();
          expect(image.debugDisposed, false);
          image.dispose();
          refined.complete();
        },
      );
      baseline!.dispose();
      await refined.future;
      expect(worker.cache.length, 0);
      expect(worker.prepared, isNull);
    } finally {
      worker.dispose();
    }
  });

  for (final action in ['cancel', 'edit', 'close']) {
    test(
      '$action during evidence read suppresses semantic replacement',
      () async {
        final s = await PdfSession.open(
          'test/fixtures/target_preview/linked_objects.pdf',
        );
        final worker = LinkPreviewWorker();
        final store = _SnapshotStore(temp, snapshot(2), delayed: true);
        var replacements = 0;
        try {
          final link = (await s.lease.document.pages.first.loadLinks())[2];
          final baseline = await worker.load(
            s,
            link.dest!,
            pixelRatio: 1,
            request: LinkPreviewRequest(
              session: s,
              sourcePage: 1,
              annotationIndex: 2,
              sourceRects: link.rects,
              destination: link.dest!,
              pixelRatio: 1,
            ),
            repository: PreviewLayoutRepository(store, _identity(s)),
            onRefinement: (image, target) {
              replacements++;
              image.dispose();
            },
          );
          baseline!.dispose();
          await store.started.future;
          if (action == 'close') {
            await s.close(); // Disk evidence must not hold a PDF lease/lock.
          } else if (action == 'edit') {
            s.revision++;
          } else {
            worker.cancel();
          }
          store.release.complete();
          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect(replacements, 0);
          expect(worker.prepared, isNull);
        } finally {
          if (!store.release.isCompleted) store.release.complete();
          worker.dispose();
          if (!s.lease.isClosed) await s.close();
        }
      },
    );
  }
}

PreviewAnalysisIdentity _identity(PdfSession session) =>
    PreviewAnalysisIdentity(
      analysisDocumentRef(session),
      ['fixture-manifest'],
      'fixture-layout',
      podoco.ComputePolicy.cpuAndNeuralEngine,
    );

class _SnapshotStore extends AnalysisStore {
  _SnapshotStore(super.directory, this.evidence, {this.delayed = false});
  final AnalysisPageSnapshot evidence;
  final bool delayed;
  final started = Completer<void>(), release = Completer<void>();
  @override
  Future<AnalysisPageSnapshot?> read(
    String key,
    int pageIndex,
    podoco.DocumentRef document,
  ) async {
    if (!started.isCompleted) started.complete();
    if (delayed) await release.future;
    return evidence;
  }
}
