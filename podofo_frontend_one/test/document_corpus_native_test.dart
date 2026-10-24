import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// Test-only handle accounting, not a native memory measurement.
// ignore: implementation_imports
import 'package:mlsr/src/bindings.g.dart' as native;
import 'package:mlsr_app_models/app_models.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:podofo_one/src/narration/mlsr_narrator.dart';
import 'package:podofo_one/src/narration/narrator.dart';
import 'package:podofo_one/src/narration/paper_plan.dart';
import 'package:podofo_one/src/narration/paper_sequence.dart';
import 'package:podofo_one/src/services/pdf_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'real paper duration coverage retains review and native failures',
    () async {
      const channel = MethodChannel('dev.mlsr.flutter/models');
      final resources = Directory(
        '.mlsr/model_assets/${AppModels.supertonic3.assetPath}',
      ).absolute;
      // Only plugin resource discovery is substituted in the Flutter runner.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (call) async => switch (call.method) {
              'platform' => 'macos-arm64',
              'locate' => resources.path,
              _ => throw StateError('Unexpected resource call: ${call.method}'),
            },
          );
      final temporary = await Directory.systemTemp.createTemp(
        'timeline-corpus-',
      );
      await pdfrxInitialize(tmpPath: temporary.path);
      final baseline = native.mlsr_live_handles();
      NarratorSession? session;
      final report = <String, Object?>{
        'started_at': DateTime.now().toUtc().toIso8601String(),
        'os': Platform.operatingSystemVersion,
        'native_provenance': jsonDecode(
          File('.mlsr/native/provenance.json').readAsStringSync(),
        ),
        'model_manifest_sha256': sha256
            .convert(
              File('${resources.path}/mlsr-bundle.yaml').readAsBytesSync(),
            )
            .toString(),
        'timing_boundary':
            'index and serial native planning after engine open; no PCM',
        'cases': <Map<String, Object?>>[],
        'passed': false,
      };
      try {
        final open = Stopwatch()..start();
        session = await MlsrNarrator.open((_) {}, volume: 0);
        report['engine_open_ms'] = open.elapsedMicroseconds / 1000;
        final inputPaths = Platform.environment['PODOFO_TIMELINE_CORPUS'];
        final files = inputPaths == null
            ? [
                'build/mlsr-qualification/corpus/vit.pdf',
                'build/mlsr-qualification/corpus/resnet.pdf',
              ]
            : (jsonDecode(inputPaths) as List).cast<String>();
        for (final path in files) {
          final file = File(path);
          final document = await PdfSession.open(file.path);
          try {
            final paper = PaperSequence(document, const PaperReadOptions());
            try {
              final timer = Stopwatch()..start();
              paper.configureTiming(
                session as NarrationDurationSession,
                const NarrationSettings(),
              );
              await paper.timingIdle;
              final timeline = paper.timeline.snapshot;
              final index = paper.index.snapshot;
              expect(timeline.planning, false);
              expect(index.scanFinished, true);
              expect(
                timeline.plannedPassages + timeline.failedPassages,
                timeline.passageCount,
              );
              if (timeline.unresolvedPages > 0) {
                expect(timeline.totalMicroseconds, isNull);
                expect(paper.timeline.freeze(), isNull);
              } else if (timeline.passageCount > 0) {
                final scale = paper.timeline.freeze()!;
                expect(timeline.fallbackPassages, timeline.failedPassages);
                for (final passage in index.passages) {
                  final prefix = paper.timeline.prefixMicroseconds(passage.id)!;
                  final target = scale.targetAt(prefix);
                  if (paper.timeline.timing(passage.id) == null) {
                    expect(target, isNull);
                    expect(scale.unavailablePassageAt(prefix)?.id, passage.id);
                  } else {
                    expect(target?.passage.id, passage.id);
                  }
                }
              }
              expect(paper.cachedPageCount, 0);
              expect(native.mlsr_live_handles(), baseline + 1);
              (report['cases'] as List).add({
                'path': file.absolute.path,
                'pdf_sha256': sha256.convert(file.readAsBytesSync()).toString(),
                'order': 'pdfOrder',
                'plan_version': PaperPlanner.version,
                'settings': const NarrationSettings().key,
                'elapsed_ms': timer.elapsedMicroseconds / 1000,
                'scope_end_page': index.scopeEndPage,
                'physical_pages': index.pageCount,
                'planned_passages': timeline.plannedPassages,
                'passages': timeline.passageCount,
                'known_duration_us': timeline.knownMicroseconds,
                'total_duration_us': timeline.totalMicroseconds,
                'fallback_passages': timeline.fallbackPassages,
                'unresolved_pages': [
                  for (final page in index.unresolvedPages)
                    {'page': page.page, 'issue': page.issue},
                ],
                'failed_passages': [
                  for (final p in index.passages)
                    if (paper.timeline.failure(p.id) case final error?)
                      {
                        'page': p.page,
                        'ordinal': p.ordinal,
                        'text_sha256': p.spokenTextHash,
                        'error': error,
                      },
                ],
                'retained_timing_count': paper.timeline.retainedTimingCount,
                'cached_pages': paper.cachedPageCount,
                'live_handles': native.mlsr_live_handles(),
                'rss_bytes': ProcessInfo.currentRss,
              });
            } finally {
              paper.close();
              await paper.timingIdle;
            }
          } finally {
            await document.close(discard: true);
          }
        }
        report['passed'] = true;
      } finally {
        await session?.dispose();
        report['handles_before'] = baseline;
        report['handles_after'] = native.mlsr_live_handles();
        final output = File(
          Platform.environment['PODOFO_TIMELINE_REPORT'] ??
              'build/document-timeline-qualification/milestone6/corpus.json',
        );
        await output.parent.create(recursive: true);
        await output.writeAsString(
          '${const JsonEncoder.withIndent('  ').convert(report)}\n',
        );
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        await PdfrxEntryFunctions.instance.stopBackgroundWorker();
        await temporary.delete(recursive: true);
      }
      expect(native.mlsr_live_handles(), baseline);
    },
    skip: Platform.environment['PODOFO_TEST_MLSR_CORPUS'] != '1',
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
