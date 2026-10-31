import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:podoco/podoco.dart' as podoco;
import 'package:podofo_one/src/analysis/analysis_snapshot.dart';
import 'package:podofo_one/src/analysis/pdf_analysis_source.dart';
import 'package:podofo_one/src/services/pdf_session.dart';
import 'package:podofo_one/src/previews/link_target.dart';
import 'package:podofo_one/src/previews/link_target_resolver.dart';
import 'package:podofo_one/src/previews/pdf_link_context.dart';
import 'package:podofo_one/src/analysis/preview_layout_repository.dart';
import 'package:podofo_one/src/workers/link_preview_worker.dart';

import 'support/target_preview_metrics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final bundle = Platform.environment['PODOCO_M2_BUNDLE'];
  final corpus = Platform.environment['TARGET_PREVIEW_CORPUS_DIR'];
  final run = Platform.environment['TARGET_PREVIEW_RUN'];
  test(
    'capture real layout evidence for frozen preview links',
    () async {
      final out = Directory('build/target-preview-evaluation/$run');
      await out.create(recursive: true);
      await pdfrxInitialize(tmpPath: out.absolute.path);
      final analyzer = await podoco.Analyzer.open(
        await podoco.ModelBundle.verify(bundle!),
        options: podoco.AnalyzerOptions(
          computePolicy: podoco.ComputePolicy.cpuAndNeuralEngine,
          limits: podoco.ResourceLimits(
            queuedJobs: 2,
            inputBytes: 16 * 1024 * 1024,
            pendingUpdates: 2,
            resultBytes: 4 * 1024 * 1024,
            maxUpdateBytes: 2 * 1024 * 1024,
            tensorBytes: 128 * 1024 * 1024,
            decoderCacheBytes: 1,
          ),
        ),
      );
      final documents = [
        jsonDecode(
          File('test/fixtures/target_preview/linked_objects.json')
              .readAsStringSync(),
        ) as Map,
        ...(jsonDecode(
                  File('test/fixtures/target_preview/real_papers.json')
                      .readAsStringSync(),
                )['documents']
                as List)
            .cast<Map>(),
      ];
      final records = <Map<String, Object?>>[];
      try {
        for (final doc in documents) {
          final file = File(
            '${doc['id'] == null ? 'test/fixtures/target_preview' : corpus}/${doc['pdf']}',
          );
          expect(
            sha256.convert(await file.readAsBytes()).toString(),
            doc['sha256'],
          );
          final session = await PdfSession.open(file.path);
          try {
            final source = await PdfAnalysisSource.create(session);
            final pages = (doc['cases'] as List)
                .map((c) => (c['destination']['page'] as int) - 1)
                .toSet();
            for (final index in pages) {
              AnalysisPageSnapshot? snapshot;
              final timer = Stopwatch()..start();
              final job = analyzer.analyzePage(
                page: source.pages[index],
                loadPage: source.loadPage,
                options: podoco.AnalysisOptions(
                  profile: analyzer.profile,
                  formulaScope: podoco.FormulaScope.none,
                  requireReadingOrder: true,
                ),
                onUpdate: (u) async {
                  if (u is podoco.PageFinished) {
                    snapshot = AnalysisPageSnapshot.fromUpdate(u);
                  }
                },
              );
              try {
                expect(
                  (await job.done).status,
                  podoco.CompletionStatus.completed,
                );
                expect(snapshot, isNotNull);
                await File('${out.path}/${doc['pdf']}-page-${index + 1}.json')
                    .writeAsString(
                      const JsonEncoder.withIndent('  ').convert({
                        'elapsed_us': timer.elapsedMicroseconds,
                        'snapshot': snapshot!.toJson(),
                      }),
                    );
              } finally {
                await job.dispose();
              }
            }
            final context = PdfLinkContext();
            try {
              for (final c in doc['cases'] as List) {
                final sourcePage =
                    session.lease.document.pages[(c['source_page'] as int) - 1];
                final links = await sourcePage.loadLinks();
                final b = (c['source_bounds'] as List).cast<num>();
                final box = ui.Rect.fromLTRB(
                  b[0].toDouble(),
                  b[1].toDouble(),
                  b[2].toDouble(),
                  b[3].toDouble(),
                );
                final link = links.singleWhere(
                  (l) => l.rects.any(
                    (r) =>
                        (r.toRect(page: sourcePage).center - box.center)
                            .distance <
                        .1,
                  ),
                );
                final request = LinkPreviewRequest(
                  session: session,
                  sourcePage: sourcePage.pageNumber,
                  annotationIndex: links.indexOf(link),
                  sourceRects: link.rects,
                  destination: link.dest!,
                  pixelRatio: 1,
                );
                final prepared = (await context.prepare(
                  request,
                  () => true,
                  null,
                ))!;
                final captured = jsonDecode(
                  await File(
                    '${out.path}/${doc['pdf']}-page-${link.dest!.pageNumber}.json',
                  ).readAsString(),
                );
                final layout = PreviewLayoutEvidence(
                  AnalysisPageSnapshot.fromJson(
                    Map<String, Object?>.from(captured['snapshot']),
                  ),
                );
                final target = const LinkTargetResolver().resolve(
                  prepared.destination,
                  source: prepared.source,
                  text: prepared.targetText,
                  layout: layout,
                );
                final baseline = (await session.readLocked(
                  (pdf) => renderLinkPreview(
                    pdf,
                    link.dest!,
                    1,
                    LinkPreviewCancellation(),
                  ),
                ))!;
                try {
                  await File(
                    '${out.path}/${c['id']}-baseline.png',
                  ).writeAsBytes(
                    (await baseline.toByteData(format: ui.ImageByteFormat.png))!
                        .buffer
                        .asUint8List(),
                  );
                } finally {
                  baseline.dispose();
                }
                final semantic = await session.readLocked(
                  (pdf) => renderResolvedLinkPreview(
                    pdf,
                    target,
                    1,
                    LinkPreviewCancellation(),
                  ),
                );
                if (semantic != null) {
                  try {
                    await File('${out.path}/${c['id']}-semantic.png')
                        .writeAsBytes(
                          (await semantic.toByteData(
                            format: ui.ImageByteFormat.png,
                          ))!.buffer.asUint8List(),
                        );
                  } finally {
                    semantic.dispose();
                  }
                }
                final metrics = await previewPixelMetrics(
                  session.lease.document.pages[link.dest!.pageNumber - 1],
                  target.parts.map((p) => p.bounds).toList(),
                  (c['required_parts'] as List)
                      .map(previewFixtureRect)
                      .toList(),
                  (c['excluded_neighbors'] as List)
                      .map(previewFixtureRect)
                      .toList(),
                );
                expect(target.kind?.name, c['kind'], reason: c['id'] as String);
                expect(semantic, isNotNull, reason: c['id'] as String);
                for (final m in metrics['required'] as List) {
                  expect(m['ink'], greaterThan(0), reason: c['id'] as String);
                  expect(
                    (m['covered'] as int) / (m['ink'] as int),
                    greaterThanOrEqualTo(.995),
                    reason: c['id'] as String,
                  );
                }
                for (final m in metrics['excluded'] as List) {
                  expect(m['covered'], 0, reason: c['id'] as String);
                }
                records.add({
                  'metrics': metrics,
                  'id': c['id'],
                  'kind': target.kind?.name,
                  'reason': target.reason,
                  'label': target.label,
                  'source': prepared.source?.spans.map((s) => s.text).join(' '),
                  'before': prepared.source?.before,
                  'after': prepared.source?.after,
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
                });
              }
            } finally {
              context.clear();
            }
          } finally {
            await session.close();
          }
        }
      } finally {
        await analyzer.dispose();
        await PdfrxEntryFunctions.instance.stopBackgroundWorker();
      }
      await File('${out.path}/results.json')
          .writeAsString(const JsonEncoder.withIndent('  ').convert(records));
      expect(podoco.nativeLiveHandles, 0);
    },
    skip: bundle == null || corpus == null || run == null
        ? 'Requires explicit model, corpus, and run id'
        : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
