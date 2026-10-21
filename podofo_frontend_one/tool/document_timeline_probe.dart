// Muted real-PDF/native qualification, shared by the sandboxed release probe.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:mlsr_flutter/mlsr_flutter.dart';
import 'package:podofo_one/src/narration/narration_controller.dart';
import 'package:podofo_one/src/narration/narrator.dart';
import 'package:podofo_one/src/narration/paper_plan.dart';
import 'package:podofo_one/src/narration/paper_sequence.dart';
import 'package:podofo_one/src/services/narration_bookmarks.dart';
import 'package:podofo_one/src/services/pdf_session.dart';

import '../test/fixtures/narration_pdf_fixture.dart';

Future<Map<String, Object?>> qualifyDocumentTimeline(
  NarrationController controller,
  Tts tts,
  NarrationBookmarks bookmarks,
  Directory evidence,
) async {
  void check(bool value, String message) {
    if (!value) throw StateError(message);
  }

  Future<void> until(bool Function() condition, String stage) async {
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    while (!condition()) {
      check(controller.error == null, '$stage: ${controller.error}');
      check(DateTime.now().isBefore(deadline), 'Timed out: $stage');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  final file = File('${evidence.path}/timeline-paper.pdf')
    ..writeAsBytesSync(
      narrationPdfFixture([
        for (var page = 1; page <= 12; page++)
          'BT /F1 12 Tf 40 700 Td (Experiment $page measures a reproducible result.) Tj ET\n'
              'BT /F1 12 Tf 40 682 Td (The observation agrees with the prediction.) Tj ET\n',
        'BT /F1 18 Tf 40 700 Td (References) Tj ET\n'
            'BT /F1 12 Tf 40 660 Td (Citation content is excluded.) Tj ET\n',
        'BT /F1 12 Tf 40 700 Td (Appendix outside the selected reading scope.) Tj ET\n',
      ]),
    );
  final document = await PdfSession.open(file.path);
  final paper = PaperSequence(
    document,
    const PaperReadOptions(skipRunningMatter: false),
  );
  final result = <String, Object?>{
    'pdf_sha256': sha256.convert(file.readAsBytesSync()).toString(),
    'physical_pages': 14,
    'audio_volume': 0,
    'timing_boundary':
        'warm engine; read admission to first observed presented frame / complete coverage; '
        'seek admission to native-confirmed paused destination; 20 ms polling',
  };
  final states = <Map<String, Object?>>[];
  String? previousState;
  void observe() {
    final state = controller.snapshot;
    final key =
        '${controller.source?.passage?.anchorAt(0)?.page}:'
        '${controller.preparing}:${state?.phase}:${state?.positionFrames}:'
        '${state?.seeking}:${controller.error}';
    if (key == previousState) return;
    previousState = key;
    states.add({
      'at': DateTime.now().toUtc().toIso8601String(),
      'state': key,
      'preparation': controller.preparation,
    });
    if (states.length > 128) states.removeAt(0);
  }

  controller.addListener(observe);
  try {
    final start = Stopwatch()..start();
    await controller.read(document, () async {
      final passage = (await paper.start(page: 6))!;
      return NarrationSource(
        documentId: document,
        title: 'Document timeline qualification',
        text: passage.text,
        passage: passage,
        sequence: paper,
      );
    });
    await until(
      () => (controller.snapshot?.positionFrames ?? 0) > 0,
      'timeline first presented frame',
    );
    result['first_presented_ms'] = start.elapsedMicroseconds / 1000;
    controller.togglePause();
    await until(() => controller.paused, 'timeline pause');
    await until(
      () => controller.documentTimeline?.totalMicroseconds != null,
      'complete document duration',
    );
    result['coverage_ms'] = start.elapsedMicroseconds / 1000;
    check(paper.index.snapshot.scopeEndPage == 13, 'References scope lost');
    check(
      paper.index.snapshot.readablePassageCount == 12,
      'Unexpected passages',
    );
    check(paper.timeline.retainedTimingCount == 12, 'Missing timing');
    check(
      controller.documentPosition!.microseconds > 0,
      'Missing middle prefix',
    );
    result['scope_end_page'] = paper.index.scopeEndPage;
    result['planned_passages'] = paper.timeline.retainedTimingCount;
    result['initial_total_us'] = controller.documentTimeline!.totalMicroseconds;
    stdout.writeln('PODOFO_TIMELINE=coverage ${result['coverage_ms']} ms');
    final seeks = <Map<String, Object?>>[];
    for (var i = 0; i < 24; i++) {
      final page = i.isEven ? 1 : 12;
      final descriptor = paper.index.page(page)!.passages.single;
      final time = paper.timeline.prefixMicroseconds(descriptor.id)! + 500000;
      final timer = Stopwatch()..start();
      stdout.writeln('PODOFO_TIMELINE=seek $i to page $page');
      await controller.seekDocument(time);
      check(controller.error == null, 'Seek $i: ${controller.error}');
      check(paper.pageNumber == page, 'Seek committed the wrong page');
      check(controller.paused, 'Paused seek started playback');
      check(
        controller.currentAnchor?.page == page,
        'Anchor missed destination',
      );
      check(
        bookmarks.find(document.path)?.page == page,
        'Bookmark missed seek',
      );
      check(paper.cachedPageCount <= 2, 'Detailed page cache exceeded bound');
      check(paper.timeline.retainedTimingCount == 12, 'Timing count grew');
      seeks.add({
        'page': page,
        'confirmed_ms': timer.elapsedMicroseconds / 1000,
        'position_us': controller.documentPosition?.microseconds,
        'cached_pages': paper.cachedPageCount,
        'rss_bytes': ProcessInfo.currentRss,
      });
    }
    result['seeks'] = seeks;
    await controller.seekDocument(0);
    check(controller.documentPosition?.microseconds == 0, 'Start not exact');
    final latest = controller.seekDocument(
      controller.documentTimeline!.totalMicroseconds! ~/ 2,
    );
    await controller.stop();
    await latest;
    check(paper.pageNumber == 1, 'Stop committed an unfinished seek');
    check(bookmarks.find(document.path)?.page == 1, 'Stop moved bookmark');
    await controller.seekDocument(
      controller.documentTimeline!.totalMicroseconds!,
    );
    check(paper.pageNumber == 12 && controller.paused, 'Endpoint seek failed');
    await controller.seekDocument(0);
    controller.togglePause();
    await until(
      () => controller.snapshot?.phase == NarrationPhase.playing,
      'resume after stopped seek',
    );
    final last = paper.index.page(12)!.passages.single;
    await controller.seekDocument(paper.timeline.prefixMicroseconds(last.id)!);
    await until(
      () => controller.snapshot?.phase == NarrationPhase.playing,
      'playing seek restores intent',
    );
    controller.togglePause();
    await until(() => controller.paused, 'pause before settings');
    final rates = <Map<String, Object?>>[];
    for (final rate in [.9, 1.3]) {
      final timer = Stopwatch()..start();
      await controller.configure(NarrationSettings(speed: rate));
      await until(
        () => controller.documentTimeline?.totalMicroseconds != null,
        'rate $rate replan',
      );
      check(controller.paused, 'Rate change lost pause intent');
      await controller.seekDocument(0);
      check(paper.pageNumber == 1, 'Rate change invalidated new seeks');
      rates.add({
        'rate': rate,
        'replan_and_seek_ms': timer.elapsedMicroseconds / 1000,
        'total_us': controller.documentTimeline!.totalMicroseconds,
      });
    }
    result['rates'] = rates;
    await controller.stop();
    await paper.timingIdle;
    final retention = (await tts.snapshot()).retention;
    check(
      retention.usedBytes == 0 && retention.liveStores == 0,
      'Stop retained PCM',
    );
    result['retained_bytes_after_stop'] = retention.usedBytes;
    result['retained_stores_after_stop'] = retention.liveStores;
    result['peak_retained_bytes'] = retention.peakBytes;
    result['passed'] = true;
  } catch (error) {
    result['error'] = '$error';
    rethrow;
  } finally {
    controller.removeListener(observe);
    result['recent_states'] = states;
    await File(
      '${evidence.path}/timeline-report.json',
    ).writeAsString('${const JsonEncoder.withIndent('  ').convert(result)}\n');
    await controller.stop();
    await paper.timingIdle;
    paper.close();
    await document.close(discard: true);
  }
  return result;
}
