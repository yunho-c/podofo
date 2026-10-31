import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
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

import 'support/file_access_mock.dart';
import 'support/target_preview_metrics.dart';

const _fixtures = 'test/fixtures/target_preview';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final run = Platform.environment['TARGET_PREVIEW_M5_RUN'];
  final corpus = Platform.environment['TARGET_PREVIEW_CORPUS_DIR'];
  test(
    'qualify every annotated paper link and retain failures and fallbacks',
    () async {
      final split =
          Platform.environment['TARGET_PREVIEW_M5_SPLIT'] ?? 'development';
      expect(['development', 'held_out'], contains(split));
      final filter = Platform.environment['TARGET_PREVIEW_M5_DOCUMENTS']
          ?.split(',')
          .toSet();
      if (split == 'held_out' && filter != null) {
        throw StateError(
          'Held-out evaluation must include its entire frozen split',
        );
      }
      final sampling = jsonDecode(
        File('$_fixtures/m5_sampling.json').readAsStringSync(),
      );
      final specs = (sampling['documents'] as List)
          .where(
            (d) =>
                d['split'] == split &&
                (filter == null ||
                    filter.contains(
                      (d['pdf'] as String).replaceFirst('.pdf', ''),
                    )),
          )
          .toList();
      expect(specs, isNotEmpty);
      if (filter != null) expect(specs.length, filter.length);
      final documents = <Map<String, dynamic>>[];
      final identities = <String, String>{};
      for (final spec in specs) {
        final name = (spec['pdf'] as String).replaceFirst('.pdf', '');
        final file = File('$_fixtures/m5_annotations/$name.json');
        final bytes = await file.readAsBytes();
        identities[file.path] = sha256.convert(bytes).toString();
        final annotation = jsonDecode(utf8.decode(bytes));
        expect(
          annotation['annotation_status'],
          'source_pages_visually_reviewed_before_resolver_output',
        );
        final doc = Map<String, dynamic>.from(annotation['document']);
        expect(doc['split'], split);
        for (final c in doc['cases']) {
          expect(c['reviewed'], true, reason: c['id']);
          expect(c['eligible'], isA<bool>(), reason: c['id']);
          if (c['eligible'] == true) {
            expect(c['required_parts'], isNotEmpty, reason: c['id']);
            expect(c['excluded_neighbors'], isNotEmpty, reason: c['id']);
          }
        }
        documents.add(doc);
      }
      for (final path in [
        'lib/src/previews/link_target.dart',
        'lib/src/previews/link_target_resolver.dart',
        'lib/src/previews/reference_targets.dart',
        'lib/src/previews/figure_targets.dart',
        'lib/src/previews/pdf_link_context.dart',
        'lib/src/previews/preview_text.dart',
      ]) {
        identities[path] = sha256
            .convert(await File(path).readAsBytes())
            .toString();
      }
      // Held-out output must not be examined until annotations and resolver code
      // have both been frozen. Any change requires a new, explicitly reviewed set.
      if (split == 'held_out') {
        final freeze = jsonDecode(
          await File('$_fixtures/m5_freeze.json').readAsString(),
        );
        expect(freeze['identities'], identities);
      }
      final out = Directory('build/target-preview-m5/papers-$run');
      if (await out.exists()) {
        throw StateError('Use a fresh run id to preserve evidence');
      }
      await out.create(recursive: true);
      installFileAccessMock();
      await pdfrxInitialize(tmpPath: out.absolute.path);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        NativeModelResources.channel,
        (call) async => call.method == 'platform'
            ? 'macos-arm64'
            : Directory('.podoco/model_assets/models').absolute.path,
      );
      final records = <Map<String, Object?>>[], issues = <String>[];
      var completed = false;
      try {
        for (final doc in documents) {
          final file = File('$corpus/${doc['pdf']}');
          expect(
            sha256.convert(await file.readAsBytes()).toString(),
            doc['sha256'],
          );
          final dir = Directory('${out.path}/${doc['id']}');
          await dir.create();
          final replay = Platform.environment['TARGET_PREVIEW_M5_REPLAY'];
          if (replay != null) {
            final prior = Directory('$replay/${doc['id']}/layout');
            if (await prior.exists()) {
              await Directory('${dir.path}/layout').create();
              await for (final entry in prior.list()) {
                if (entry is File && entry.path.endsWith('.json')) {
                  await entry.copy(
                    '${dir.path}/layout/${entry.uri.pathSegments.last}',
                  );
                }
              }
            }
          }
          final session = await PdfSession.open(file.path),
              context = PdfLinkContext();
          final analysis = AnalysisController(
            store: AnalysisStore(Directory('${dir.path}/manual')),
            previewStore: PreviewLayoutStore(Directory('${dir.path}/layout')),
            openBundledLayout: NativeAnalysisEngine.openBundledLayout,
          )..select(session, 0);
          try {
            for (final c in doc['cases']) {
              final source =
                  session.lease.document.pages[(c['source_page'] as int) - 1];
              final sourceBox = previewFixtureRect(c['source_bounds']);
              final links = await source.loadLinks();
              final link = links.singleWhere(
                (l) => l.rects.any(
                  (r) =>
                      (r.toRect(page: source).center - sourceBox.center)
                          .distance <
                      .15,
                ),
              );
              expect(
                link.dest!.pageNumber,
                c['destination']['page'],
                reason: c['id'],
              );
              final request = LinkPreviewRequest(
                session: session,
                sourcePage: source.pageNumber,
                annotationIndex: links.indexOf(link),
                sourceRects: link.rects,
                destination: link.dest!,
                pixelRatio: 2,
              );
              final baseline = (await session.readLocked(
                (pdf) => renderLinkPreview(
                  pdf,
                  link.dest!,
                  2,
                  LinkPreviewCancellation(),
                ),
              ))!;
              await _save(baseline, '${dir.path}/${c['id']}-context.png');
              final watch = Stopwatch()..start();
              final prepared = (await context.prepare(
                request,
                () => true,
                analysis.previewRepository,
              ))!;
              final resolutionUs = watch.elapsedMicroseconds,
                  target = prepared.resolution;
              final point = c['destination']['point'] as List;
              if (prepared.destination?.x case final x?) {
                expect(x, closeTo((point[0] as num).toDouble(), .15));
              }
              if (prepared.destination?.y case final y?) {
                expect(y, closeTo((point[1] as num).toDouble(), .15));
              }
              final semantic = target.tier == LinkTargetTier.matchedIdentity;
              final semanticStart = Stopwatch()..start();
              if (semantic) {
                final image = await session.readLocked(
                  (pdf) => renderResolvedLinkPreview(
                    pdf,
                    target,
                    2,
                    LinkPreviewCancellation(),
                  ),
                );
                expect(image, isNotNull, reason: c['id']);
                final renderUs = semanticStart.elapsedMicroseconds;
                await _save(image!, '${dir.path}/${c['id']}-semantic.png');
                semanticStart.stop();
                c['render_us'] = renderUs;
              }
              final metrics = <Map<String, Object>>[];
              var complete = semantic, requiredInk = 0, coveredInk = 0;
              final pages = {
                ...target.parts.map((p) => p.page),
                ...(c['required_parts'] as List).map((p) => p['page'] as int),
                ...(c['excluded_neighbors'] as List).map(
                  (p) => p['page'] as int,
                ),
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
                  final ink = m['ink'] as int, covered = m['covered'] as int;
                  expect(
                    ink,
                    greaterThan(0),
                    reason: '${c['id']}: empty required annotation',
                  );
                  requiredInk += ink;
                  coveredInk += covered;
                  if (covered / ink < .995) complete = false;
                }
                for (final m in value['excluded'] as List) {
                  expect(
                    m['ink'],
                    greaterThan(0),
                    reason: '${c['id']}: empty neighbor annotation',
                  );
                  if (m['covered'] != 0) complete = false;
                }
              }
              final wrong =
                  semantic &&
                  (c['eligible'] != true ||
                      target.kind?.name != c['kind'] ||
                      coveredInk == 0);
              if (wrong) {
                issues.add('${c['id']}: wrong object or unsupported target');
              }
              if (semantic && !complete) {
                issues.add('${c['id']}: incomplete target or neighboring ink');
              }
              records.add({
                'id': c['id'],
                'document': doc['id'],
                'split': split,
                'group': c['group'],
                'eligible': c['eligible'],
                'semantic': semantic,
                'complete': complete,
                'wrong_object': wrong,
                'required_ink': requiredInk,
                'covered_ink': coveredInk,
                'kind': target.kind?.name,
                'reason': target.reason,
                'label': target.label,
                'source': prepared.source?.spans.map((s) => s.text).join(' '),
                'before': prepared.source?.before,
                'after': prepared.source?.after,
                'evidence': target.evidenceIdentity.toString(),
                'resolution_us': resolutionUs,
                'render_us': c['render_us'],
                'parts': [
                  for (final p in target.parts)
                    {
                      'page': p.page,
                      'bounds': [
                        p.bounds.left,
                        p.bounds.top,
                        p.bounds.right,
                        p.bounds.bottom,
                      ],
                    },
                ],
                'metrics': metrics,
              });
            }
            expect(session.revision, 0);
            expect(session.navigationHistory.previous, isNull);
            expect(analysis.visibleSnapshot, isNull);
          } finally {
            context.clear();
            await analysis.close();
            analysis.dispose();
            await session.close();
          }
          expect(podoco.nativeLiveHandles, 0);
        }
        completed = true;
      } finally {
        messenger.setMockMethodCallHandler(NativeModelResources.channel, null);
        await PdfrxEntryFunctions.instance.stopBackgroundWorker();
        await File('${out.path}/results.json').writeAsString(
          const JsonEncoder.withIndent('  ').convert({
            'capture_complete': completed,
            'split': split,
            'resolver_version': linkResolverVersion,
            'identities': identities,
            'records': records,
            'issues': issues,
            'summary': _summary(records),
            'native_handles_after_close': podoco.nativeLiveHandles,
          }),
        );
      }
      expect(
        records.length,
        documents.fold<int>(0, (n, d) => n + (d['cases'] as List).length),
      );
      expect(
        issues,
        isEmpty,
        reason: 'Review retained wrong-object/completeness failures',
      );
      if (split == 'held_out') {
        final summary = _summary(records);
        for (final group in [
          'citation',
          'figure_table',
          'equation',
          'section',
        ]) {
          final s = summary[group]!;
          expect(s['eligible'], greaterThanOrEqualTo(10));
          expect(
            s['resolved']! / s['eligible']!,
            greaterThanOrEqualTo(.8),
            reason: group,
          );
          expect(
            s['complete']! / s['resolved']!,
            greaterThanOrEqualTo(.9),
            reason: group,
          );
        }
      }
    },
    skip: run == null || corpus == null
        ? 'Set TARGET_PREVIEW_M5_RUN and TARGET_PREVIEW_CORPUS_DIR'
        : false,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

Map<String, Map<String, int>> _summary(List<Map<String, Object?>> records) => {
  for (final group in records.map((r) => r['group'] as String).toSet())
    group: {
      'sampled': records.where((r) => r['group'] == group).length,
      'eligible': records
          .where((r) => r['group'] == group && r['eligible'] == true)
          .length,
      'resolved': records
          .where(
            (r) =>
                r['group'] == group &&
                r['eligible'] == true &&
                r['semantic'] == true,
          )
          .length,
      'complete': records
          .where(
            (r) =>
                r['group'] == group &&
                r['eligible'] == true &&
                r['complete'] == true,
          )
          .length,
      'wrong': records
          .where((r) => r['group'] == group && r['wrong_object'] == true)
          .length,
    },
};

Future<void> _save(ui.Image image, String path) async {
  try {
    await File(path).writeAsBytes(
      (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer
          .asUint8List(),
    );
  } finally {
    image.dispose();
  }
}
