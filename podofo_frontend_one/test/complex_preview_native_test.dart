import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:podoco/podoco.dart' as podoco;
import 'package:podoco_flutter/podoco_flutter.dart';
import 'package:podofo_one/src/analysis/analysis_controller.dart';
import 'package:podofo_one/src/analysis/analysis_engine.dart';
import 'package:podofo_one/src/analysis/analysis_store.dart';
import 'package:podofo_one/src/analysis/preview_layout_store.dart';
import 'package:podofo_one/src/previews/link_target.dart';
import 'package:podofo_one/src/previews/pdf_link_context.dart';
import 'package:podofo_one/src/services/pdf_session.dart';
import 'package:podofo_one/src/workers/link_preview_worker.dart';

import 'support/complex_preview_fixture.dart';
import 'support/file_access_mock.dart';
import 'support/target_preview_metrics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final run = Platform.environment['TARGET_PREVIEW_M4_RUN'];
  test(
    'real bundled layout qualifies accepted complex targets and retains every fallback',
    () async {
      installFileAccessMock();
      final out = Directory('build/target-preview-m4/native-$run');
      if (await out.exists()) {
        throw StateError('Use a new run id to preserve previous evidence');
      }
      await out.create(recursive: true);
      await pdfrxInitialize(tmpPath: out.absolute.path);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        NativeModelResources.channel,
        (call) async => call.method == 'platform'
            ? 'macos-arm64'
            : Directory('.podoco/model_assets/models').absolute.path,
      );
      final session = await PdfSession.open(
        'test/fixtures/target_preview/complex_objects.pdf',
      );
      final fixture = ComplexPreviewFixture(), context = PdfLinkContext();
      final analyzed = <int>[];
      var opened = 0;
      final analysis = AnalysisController(
        store: AnalysisStore(Directory('${out.path}/manual')),
        previewStore: PreviewLayoutStore(Directory('${out.path}/layout')),
        openBundledLayout: (progress) async {
          opened++;
          final engine = await NativeAnalysisEngine.openBundledLayout(progress);
          expect(engine.manifests, hasLength(1));
          expect(engine.recognizesFormulas, false);
          return _CaptureEngine(engine, analyzed, out);
        },
      )..select(session, 0);
      final records = <Map<String, Object?>>[], issues = <String>[];
      try {
        // Starting with this case proves that any next-page analysis is caused by
        // its continuation evidence, rather than a prior hover warming that page.
        for (final c in [
          fixture.entry('cross-page'),
          ...fixture.cases.where((c) => c['id'] != 'cross-page'),
        ]) {
          final request = await fixture.request(session, c['id']);
          final previous = analyzed.length;
          final watch = Stopwatch()..start();
          final prepared = (await context.prepare(
            request,
            () => true,
            analysis.previewRepository,
          ))!;
          final target = prepared.resolution;
          final baseline = (await session.readLocked(
            (pdf) => renderLinkPreview(
              pdf,
              request.destination,
              1,
              LinkPreviewCancellation(),
            ),
          ))!;
          try {
            await _save(baseline, '${out.path}/${c['id']}-context.png');
          } finally {
            baseline.dispose();
          }
          final metrics = <Map<String, Object>>[];
          if (target.tier == LinkTargetTier.matchedIdentity) {
            if (target.kind?.name != c['kind']) {
              issues.add('${c['id']}: wrong kind ${target.kind}');
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
              await _save(image, '${out.path}/${c['id']}-semantic.png');
            } finally {
              image.dispose();
            }
            final pages = {
              ...target.parts.map((p) => p.page),
              ...(c['required_parts'] as List).map((p) => p['page'] as int),
            };
            for (final page in pages) {
              final value = await previewPixelMetrics(
                session.lease.document.pages[page - 1],
                target.parts
                    .where((p) => p.page == page)
                    .map((p) => p.bounds)
                    .toList(),
                (c['required_parts'] as List)
                    .where((p) => p['page'] == page)
                    .map((p) => previewFixtureRect(p['bounds']))
                    .toList(),
                (c['excluded_neighbors'] as List)
                    .where((p) => p['page'] == page)
                    .map((p) => previewFixtureRect(p['bounds']))
                    .toList(),
              );
              metrics.add({'page': page, ...value});
              for (final m in value['required'] as List) {
                if ((m['ink'] as int) == 0 ||
                    (m['covered'] as int) / (m['ink'] as int) < .995) {
                  issues.add(
                    '${c['id']}: missing required ink on page $page ($m)',
                  );
                }
              }
              for (final m in value['excluded'] as List) {
                if (m['covered'] != 0) {
                  issues.add('${c['id']}: neighboring ink on page $page ($m)');
                }
              }
            }
          } else {
            expect(target.parts, isEmpty);
            if (![
              'separated-panels',
              'rotated-cropped',
              'ambiguous-label',
              'unfinished-entry',
            ].contains(c['id'])) {
              issues.add(
                '${c['id']}: previously qualified target fell back (${target.reason})',
              );
            }
          }
          records.add({
            'id': c['id'],
            'expected_kind': c['kind'],
            'kind': target.kind?.name,
            'reason': target.reason,
            'continuation_page': target.continuationPage,
            'source': prepared.source?.spans.map((s) => s.text).join(' '),
            'evidence': target.evidenceIdentity.toString(),
            'analyzed_pages': analyzed.skip(previous).toList(),
            'elapsed_us': watch.elapsedMicroseconds,
            'parts': target.parts
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
          });
        }
        expect(opened, 1);
        expect(records.first['analyzed_pages'], [4, 5]);
        expect(records.first['kind'], 'citation');
        expect(analyzed.toSet().length, analyzed.length);
        expect(analyzed.every((p) => p >= 2 && p <= 6), true);
        expect(analysis.visibleSnapshot, isNull);
        expect(session.revision, 0);
        expect(session.navigationHistory.previous, isNull);
      } finally {
        context.clear();
        await analysis.close();
        analysis.dispose();
        await session.close();
        await PdfrxEntryFunctions.instance.stopBackgroundWorker();
        await File('${out.path}/results.json').writeAsString(
          const JsonEncoder.withIndent('  ').convert({
            'resolver_version': linkResolverVersion,
            'opened_layout_engines': opened,
            'analyzed_pages': analyzed,
            'native_handles_after_close': podoco.nativeLiveHandles,
            'records': records,
            'issues': issues,
          }),
        );
      }
      expect(records, hasLength(11));
      expect(podoco.nativeLiveHandles, 0);
      expect(
        issues,
        isEmpty,
        reason: 'Review all captured native layout/completeness failures',
      );
    },
    skip: run == null
        ? 'Set TARGET_PREVIEW_M4_RUN to a fresh evidence directory suffix'
        : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

Future<void> _save(ui.Image image, String path) async => File(path)
    .writeAsBytes(
      (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer
          .asUint8List(),
    );

class _CaptureEngine implements AnalysisEngine {
  _CaptureEngine(this.delegate, this.pages, this.out);
  final AnalysisEngine delegate;
  final List<int> pages;
  final Directory out;
  @override
  String get profile => delegate.profile;
  @override
  List<String> get manifests => delegate.manifests;
  @override
  podoco.ComputePolicy get computePolicy => delegate.computePolicy;
  @override
  bool get recognizesFormulas => delegate.recognizesFormulas;
  @override
  DocumentAnalysisJob analyze(
    podoco.PageSource source,
    Future<void> Function(podoco.AnalysisUpdate) sink,
  ) => throw StateError('Hover must never analyze a document');
  @override
  DocumentAnalysisJob analyzePage(
    podoco.PageSource source,
    int pageIndex,
    Future<void> Function(podoco.AnalysisUpdate) sink, {
    podoco.FormulaScope formulaScope = podoco.FormulaScope.none,
  }) {
    expect(formulaScope, podoco.FormulaScope.none);
    pages.add(pageIndex + 1);
    return delegate.analyzePage(source, pageIndex, (update) async {
      if (update is podoco.PageLayoutReady || update is podoco.PageFinished) {
        await File('${out.path}/page-${pageIndex + 1}.json').writeAsString(
          const JsonEncoder.withIndent('  ')
              .convert(AnalysisPageSnapshot.fromUpdate(update).toJson()),
        );
      }
      await sink(update);
    }, formulaScope: formulaScope);
  }

  @override
  Future<void> close() => delegate.close();
}
