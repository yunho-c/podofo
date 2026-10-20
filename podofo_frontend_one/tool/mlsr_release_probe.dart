// Separate qualification entrypoint. The ordinary app never invokes this probe.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:mlsr_app_models/app_models.dart';
import 'package:mlsr_flutter/mlsr_flutter.dart';
// Registry accounting is diagnostic only; all synthesis uses the public SDK.
// ignore: implementation_imports
import 'package:mlsr/src/bindings.g.dart' as native;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:podofo_one/objectbox.g.dart';
import 'package:podofo_one/src/narration/mlsr_narrator.dart';
import 'package:podofo_one/src/narration/narration_controller.dart';
import 'package:podofo_one/src/narration/narrator.dart';
import 'package:podofo_one/src/narration/paper_plan.dart';
import 'package:podofo_one/src/narration/paper_sequence.dart';
import 'package:podofo_one/src/services/narration_bookmarks.dart';
import 'package:podofo_one/src/services/pdf_session.dart';

import '../test/fixtures/narration_pdf_fixture.dart';

void require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(
      home: Scaffold(
        body: Center(child: Text('PoDoFo release qualification is running.')),
      ),
    ),
  );
  final report = <String, Object?>{
    'passed': false,
    'executable': Platform.resolvedExecutable,
    'os': Platform.operatingSystemVersion,
    'dart': Platform.version,
    'started_at': DateTime.now().toUtc().toIso8601String(),
    'audio_volume': 0,
    'timing_boundary':
        'read admission to first observed presented frame; 20 ms polling',
  };
  void stage(String value) {
    report['stage'] = value;
    stdout.writeln('PODOFO_MLSR_STAGE=$value');
  }

  Directory? evidence;
  PdfSession? pdf;
  Store? store;
  NarrationController? controller;
  Tts? tts;
  final clock = Stopwatch()..start();
  var peakRss = ProcessInfo.currentRss, peakHandles = 0;
  final sample = Timer.periodic(const Duration(milliseconds: 50), (_) {
    if (ProcessInfo.currentRss > peakRss) peakRss = ProcessInfo.currentRss;
    final handles = native.mlsr_live_handles();
    if (handles > peakHandles) peakHandles = handles;
  });
  try {
    stage('sandbox and plugins');
    final support = await getApplicationSupportDirectory();
    await support.create(recursive: true);
    evidence = await support.createTemp('mlsr-qualification-');
    report['evidence_directory'] = evidence.path;
    report['handles_before'] = native.mlsr_live_handles();
    final forbidden = jsonDecode(
      Platform.environment['PODOFO_FORBIDDEN_FILES'] ?? '[]',
    ) as List;
    require(forbidden.length >= 2, 'Provide existing developer-file probes');
    final denied = <String>[];
    for (final path in forbidden.cast<String>()) {
      try {
        final file = await File(path).open();
        await file.close();
        throw StateError('Developer file was readable: $path');
      } on FileSystemException catch (error) {
        require(
          [1, 13].contains(error.osError?.errorCode),
          'Not an explicit sandbox denial: $error',
        );
        denied.add(path);
      }
    }
    report['developer_files_denied'] = denied;
    try {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        int.parse(Platform.environment['PODOFO_DENIED_NETWORK_PORT']!),
        timeout: const Duration(seconds: 2),
      );
      socket.destroy();
      throw StateError('Network access was permitted');
    } on SocketException catch (error) {
      require(
        [1, 13].contains(error.osError?.errorCode),
        'Network was not explicitly denied: $error',
      );
      report['network_denied_errno'] = error.osError?.errorCode;
    }
    await pdfrxFlutterInitialize();
    const firstText =
        'The paper compares two measurements. The results agree with the prediction.';
    final paper = File('${evidence.path}/qualification-paper.pdf')
      ..writeAsBytesSync(
        narrationPdfFixture([
          'BT /F1 12 Tf 40 700 Td (The paper compares two measurements.) Tj ET\n'
              'BT /F1 12 Tf 40 682 Td (The results agree with the prediction.) Tj ET\n'
              'BT /F1 12 Tf 40 600 Td (A second experiment checks the result.) Tj ET\n',
          'BT /F1 12 Tf 40 700 Td (The conclusion follows from the evidence.) Tj ET\n',
        ]),
      );
    pdf = await PdfSession.open(paper.path);
    store = await openStore(
      directory: '${evidence.path}/database',
      macosApplicationGroup: 'group.podofo',
    );
    final bookmarks = NarrationBookmarks(store);
    var opens = 0;
    controller = NarrationController(
      open: (progress) async {
        opens++;
        final loading = Stopwatch()..start();
        tts = await FlutterMlsr.openTts(
          model: AppModels.supertonic3,
          onProgress: (value) => progress(value.stage.name),
        );
        report['engine_open_ms'] = loading.elapsedMicroseconds / 1000;
        return MlsrNarrator.fromTts(tts!, volume: 0);
      },
      onPosition: (_, anchor) => bookmarks.save(pdf!.path, anchor),
    );
    final narration = controller;
    final document = pdf;
    Future<void> until(bool Function() condition, String stage) async {
      final deadline = DateTime.now().add(const Duration(seconds: 90));
      while (!condition()) {
        require(narration.error == null, '$stage: ${narration.error}');
        require(DateTime.now().isBefore(deadline), 'Timed out: $stage');
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    final sequence = PaperSequence(document, const PaperReadOptions());
    final passages = <String>[], transitions = <double>[];
    double? gapStart;
    String? playingText;
    narration.addListener(() {
      if (narration.preparing && narration.source != null) {
        gapStart ??= clock.elapsedMicroseconds / 1000;
      }
      if ((narration.snapshot?.positionFrames ?? 0) > 0 &&
          !narration.preparing) {
        final text = narration.source?.text;
        if (text != null && text != playingText) {
          if (playingText != null && gapStart != null) {
            transitions.add(clock.elapsedMicroseconds / 1000 - gapStart!);
          }
          playingText = text;
          passages.add(text);
          gapStart = null;
        }
      }
    });
    final admission = Stopwatch()..start();
    stage('cold load and continuous paper');
    await narration.read(document, () async {
      final passage = (await sequence.start())!;
      return NarrationSource(
        documentId: document,
        title: 'Qualification paper',
        text: passage.text,
        passage: passage,
        sequence: sequence,
      );
    });
    await until(
      () => (narration.snapshot?.positionFrames ?? 0) > 0,
      'cold first audio',
    );
    report['cold_first_presented_ms'] = admission.elapsedMicroseconds / 1000;
    await until(
      () => (narration.snapshot?.positionFrames ?? 0) > 4096,
      'audio before pause',
    );
    require(
      narration.voices.length == 10,
      'Expected the packaged ten-voice catalog',
    );
    narration.togglePause();
    await until(
      () => narration.snapshot?.phase == NarrationPhase.paused,
      'pause',
    );
    final paused = narration.snapshot!.positionFrames;
    await Future<void>.delayed(const Duration(milliseconds: 400));
    require(
      narration.snapshot!.positionFrames == paused,
      'Paused cursor moved',
    );
    narration.togglePause();
    await until(
      () => (narration.snapshot?.positionFrames ?? 0) > paused,
      'resume',
    );
    await until(
      () =>
          passages.length == 3 &&
          narration.snapshot?.phase == NarrationPhase.completed &&
          !narration.preparing,
      'continuous drain',
    );
    require(
      passages.length == 3,
      'Expected three complete passages, saw ${passages.length}',
    );
    report['continuous_passages'] = List.of(passages);
    report['transition_ms'] = List.of(transitions);
    report['cached_pages'] = sequence.cachedPageCount;
    require(sequence.cachedPageCount <= 2, 'Page cache exceeded its bound');
    require(
      bookmarks.find(document.path)?.page == 2,
      'Source bookmark did not follow playback',
    );
    await narration.stop();
    stage('twelve warm start-stop cycles');
    final resources = <Map<String, Object?>>[], warm = <double>[];
    for (var i = 0; i < 12; i++) {
      final started = Stopwatch()..start();
      await narration.read(
        document,
        () async => NarrationSource(
          documentId: document,
          title: 'Reuse',
          text: firstText,
        ),
      );
      await until(
        () => (narration.snapshot?.positionFrames ?? 0) > 0,
        'warm audio $i',
      );
      warm.add(started.elapsedMicroseconds / 1000);
      if (i == 0) {
        await until(() => narration.sentences.length >= 2, 'sentence plan');
        final first = narration.snapshot?.sentenceId;
        narration.navigate(forward: true);
        await until(
          () =>
              narration.snapshot?.sentenceId != null &&
              narration.snapshot?.sentenceId != first,
          'next sentence',
        );
        narration.navigate(forward: false);
        await until(
          () => narration.snapshot?.sentenceId == first,
          'previous sentence',
        );
      }
      final stop = Stopwatch()..start();
      await narration.stop();
      final retention = (await tts!.snapshot()).retention;
      require(
        retention.usedBytes == 0 && retention.liveStores == 0,
        'Stopped speech retained PCM',
      );
      require(
        retention.peakBytes <= 128 * 1024 * 1024 && retention.peakStores <= 128,
        'Retention quota exceeded',
      );
      resources.add({
        'iteration': i,
        'rss_bytes': ProcessInfo.currentRss,
        'live_handles': native.mlsr_live_handles(),
        'stop_ms': stop.elapsedMicroseconds / 1000,
        'retained_bytes': retention.usedBytes,
        'retained_stores': retention.liveStores,
        'peak_retained_bytes': retention.peakBytes,
        'peak_retained_stores': retention.peakStores,
      });
    }
    require(opens == 1, 'The engine was loaded more than once');
    report['engine_opens'] = opens;
    report['warm_first_presented_ms'] = warm;
    report['resources_after_stop'] = resources;
    stage('voice, speed and listening sample');
    await narration.configure(
      const NarrationSettings(voice: 'supertonic3:F1', speed: 1.4),
    );
    await narration.read(
      document,
      () async => NarrationSource(
        documentId: document,
        title: 'Voice change',
        text: firstText,
      ),
    );
    await until(
      () => narration.snapshot?.phase == NarrationPhase.completed,
      'new voice and speed',
    );
    await narration.stop();
    final wav = await tts!.renderToFile(
      firstText,
      '${evidence.path}/listening-sample.wav',
      options: const RequestOptions(voice: 'supertonic3:M1', locale: 'en'),
    );
    report['listening_sample'] = wav.path;
    report['sample_text'] = firstText;
    stage('cleanup');
    report['passed'] = true;
  } catch (error, stack) {
    report['error'] = '$error';
    report['stack'] = '$stack';
  } finally {
    sample.cancel();
    try {
      await controller?.close();
      await pdf?.close(discard: true);
      store?.close();
    } catch (error) {
      report['cleanup_error'] = '$error';
      report['passed'] = false;
    }
    report['handles_after'] = native.mlsr_live_handles();
    report['peak_observed_handles'] = peakHandles;
    report['peak_observed_rss_bytes'] = peakRss;
    report['elapsed_ms'] = clock.elapsedMicroseconds / 1000;
    if (report['handles_after'] != report['handles_before']) {
      report['passed'] = false;
    }
    final encoded = const JsonEncoder.withIndent('  ').convert(report);
    if (evidence != null) {
      await File('${evidence.path}/report.json').writeAsString('$encoded\n');
    }
    stdout.writeln('PODOFO_MLSR_REPORT=${jsonEncode(report)}');
    await stdout.flush();
  }
  exit(report['passed'] == true ? 0 : 1);
}
