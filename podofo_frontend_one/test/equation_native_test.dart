import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mlsr/mlsr.dart' as mlsr;
import 'package:mlsr_app_models/app_models.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:podoco/podoco.dart' as podoco;
// Test-only registry counts, separate from sampled process memory.
// ignore: implementation_imports
import 'package:mlsr/src/bindings.g.dart' as mlsr_native;
// ignore: implementation_imports
import 'package:podoco/src/bindings.g.dart' as podoco_native;
import 'package:podofo_one/src/analysis/analysis_controller.dart';
import 'package:podofo_one/src/analysis/analysis_store.dart';
import 'package:podofo_one/src/analysis/equation_controller.dart';
import 'package:podofo_one/src/narration/mlsr_narrator.dart';
import 'package:podofo_one/src/narration/narration_controller.dart';
import 'package:podofo_one/src/narration/narrator.dart';
import 'package:podofo_one/src/services/pdf_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final layout = Platform.environment['PODOCO_M2_BUNDLE'];
  final formula = Platform.environment['PODOCO_M6_BUNDLE'];
  final rules = Platform.environment['PODOCO_M7_RULES'];
  final pdf = Platform.environment['PODOCO_M8_PDF'];
  final output = Platform.environment['PODOCO_M9_OUTPUT'];
  test(
    'real progressive equations, MathCAT and concurrent muted MLSR playback',
    () async {
      final root = Directory(output!);
      await root.create(recursive: true);
      final temporary = await Directory.systemTemp.createTemp('podoco-m9-');
      await pdfrxInitialize(tmpPath: temporary.path);
      const channel = MethodChannel('dev.mlsr.flutter/models');
      final resources = Directory(
        '.mlsr/model_assets/${AppModels.supertonic3.assetPath}',
      ).absolute;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (call) async => switch (call.method) {
              'platform' => 'macos-arm64',
              'locate' => resources.path,
              _ => throw StateError(
                'Unexpected resource operation: ${call.method}',
              ),
            },
          );
      final podocoBaseline = podoco_native.podoco_live_handles();
      final mlsrBaseline = mlsr_native.mlsr_live_handles();
      final clock = Stopwatch()..start();
      final marks = <String, int>{};
      final samples = <Map<String, int>>[];
      Future<void> sample() async {
        final result = await Process.run('/bin/ps', [
          '-o',
          'rss=',
          '-p',
          '$pid',
        ]);
        final kib = int.tryParse((result.stdout as String).trim());
        if (kib != null) {
          samples.add({
            'us': clock.elapsedMicroseconds,
            'rss_bytes': kib * 1024,
          });
        }
      }

      await sample();
      var sampling = false;
      final timer = Timer.periodic(const Duration(milliseconds: 500), (
        _,
      ) async {
        if (sampling) return;
        sampling = true;
        try {
          await sample();
        } finally {
          sampling = false;
        }
      });
      final document = await PdfSession.open(pdf!);
      final analysis = AnalysisController(
        store: AnalysisStore(Directory('${temporary.path}/pages')),
      );
      final narration = NarrationController(
        open: (progress) => MlsrNarrator.open(progress, volume: 0),
      );
      final copies = <String>[];
      final equations = EquationController(
        analysis: analysis,
        narration: narration,
        copy: (text) async => copies.add(text),
      );
      Future<void> until(bool Function() condition, String stage) async {
        final deadline = DateTime.now().add(const Duration(seconds: 120));
        while (!condition()) {
          if (equations.error != null) fail('$stage: ${equations.error}');
          if (narration.error != null) fail('$stage: ${narration.error}');
          if (analysis.error != null) fail('$stage: ${analysis.error}');
          if (DateTime.now().isAfter(deadline)) fail('Timed out: $stage');
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      }

      final report = <String, Object?>{
        'schema_version': 0,
        'automated_audio_volume': 0,
        'human_listening': false,
        'podoco_version': podoco.nativeVersion,
        'mlsr_version': mlsr.nativeVersion,
        'pdf_sha256': sha256.convert(await File(pdf).readAsBytes()).toString(),
        'marks_us': marks,
        'rss_samples': samples,
        'memory_boundary': '500ms sampled test-process RSS; includes Flutter, PDFium, Core ML, MathCAT and MLSR; not an allocator peak',
        'timing_boundary': 'single active-host correctness run; elapsed marks include asynchronous work and model hashing/loading; no performance comparison',
      };
      try {
        analysis.select(document, 0);
        marks['open_start'] = clock.elapsedMicroseconds;
        await analysis.configure(layout!, formulaDirectory: formula!);
        expect(analysis.error, isNull);
        marks['analysis_opened'] = clock.elapsedMicroseconds;
        await equations.configureRules(rules!);
        expect(equations.error, isNull);
        marks['math_opened'] = clock.elapsedMicroseconds;
        // Load the shared narrator explicitly so a cold model open cannot outlast
        // this short document and accidentally turn the concurrency check serial.
        marks['narrator_open_start'] = clock.elapsedMicroseconds;
        await narration.read(
          document,
          () async => NarrationSource(
            documentId: document,
            title: 'Qualification warmup',
            text: 'One plus one.',
          ),
        );
        marks['narrator_opened'] = clock.elapsedMicroseconds;
        await until(
          () => narration.snapshot?.phase == NarrationPhase.completed,
          'narrator warmup',
        );
        await narration.dismiss();
        marks['narrator_warmup_finished'] = clock.elapsedMicroseconds;
        final run = analysis.analyze();
        marks['analysis_started'] = clock.elapsedMicroseconds;
        await until(
          () =>
              analysis.visiblePage?.formulas.any(
                (f) =>
                    f.state is podoco.FormulaFinishedState &&
                    (f.state as podoco.FormulaFinishedState).outcome
                        is podoco.FormulaRecognized,
              ) ??
              false,
          'progressive recognition',
        );
        marks['first_formula'] = clock.elapsedMicroseconds;
        expect(analysis.running, true);
        expect(analysis.pageComplete, false);
        final first = analysis.visiblePage!.formulas.firstWhere(
          (f) =>
              f.state is podoco.FormulaFinishedState &&
              (f.state as podoco.FormulaFinishedState).outcome
                  is podoco.FormulaRecognized,
        );
        equations.select(first.regionId);
        final latex = equations.selected!.recognized!.latex;
        await equations.copyLatex();
        expect(copies, [latex]);
        marks['listen_started'] = clock.elapsedMicroseconds;
        await equations.listen();
        marks['listen_ready'] = clock.elapsedMicroseconds;
        expect(equations.error, isNull);
        expect(narration.error, isNull);
        expect(narration.source?.text, equations.lastSpeechText);
        expect(equations.lastSpeechText, isNotEmpty);
        report['analysis_running_at_listen_ready'] = analysis.running;
        await until(
          () => (narration.snapshot?.positionFrames ?? 0) > 2048,
          'real audio progression',
        );
        marks['first_audio_progress'] = clock.elapsedMicroseconds;
        report['analysis_running_at_audio_progress'] = analysis.running;
        report['selected_region_id'] = first.regionId;
        report['latex'] = latex;
        report['spoken_text'] = equations.lastSpeechText;
        report['math_diagnostics'] = equations.diagnostics;
        report['audio_progress_frames'] = narration.snapshot!.positionFrames;
        expect(
          analysis.running,
          true,
          reason: 'The run must exercise overlapping analysis and speech, not only load both libraries.',
        );
        narration.togglePause();
        await until(
          () => narration.snapshot?.phase == NarrationPhase.paused,
          'pause',
        );
        final paused = narration.snapshot!.positionFrames;
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(narration.snapshot!.positionFrames, paused);
        narration.togglePause();
        await until(
          () => (narration.snapshot?.positionFrames ?? 0) > paused,
          'resume',
        );
        await run;
        marks['analysis_finished'] = clock.elapsedMicroseconds;
        expect(analysis.outcome!.status, podoco.CompletionStatus.completed);
        expect(analysis.pageComplete, true);
        final result = analysis.outcome!;
        report['analysis_outcome'] = {
          'status': result.status.name,
          'pages_finished': result.progress.processed.pagesFinished,
          'pages_total': result.progress.processed.pagesTotal,
          'formulas_recognized': result.progress.processed.formulasRecognized,
          'formulas_failed': result.progress.processed.formulasFailed,
          'formulas_truncated': result.progress.processed.formulasTruncated,
          'peak_input_bytes': result.progress.peakInputBytes,
          'peak_result_bytes': result.progress.peakResultBytes,
          'peak_pending_updates': result.progress.peakPendingUpdates,
          'error': result.error?.toString(),
        };
        report['page'] = analysis.visibleSnapshot!.toJson();
        await until(
          () => narration.snapshot?.phase == NarrationPhase.completed,
          'audio drain',
        );
        marks['playback_finished'] = clock.elapsedMicroseconds;
        report['duration_frames'] = narration.snapshot!.durationFrames;
        report['sample_rate'] = narration.snapshot!.sampleRate;
        final cached = equations.cachedBytes;
        await equations.listen();
        expect(equations.cachedBytes, cached);
        expect(narration.source!.text, report['spoken_text']);
        marks['cancel_started'] = clock.elapsedMicroseconds;
        analysis.select(null, 0);
        await narration.dismiss();
        marks['cancel_drained'] = clock.elapsedMicroseconds;
        expect(narration.active, false);
        expect(equations.selected, isNull);
        report['speech_cache_bytes'] = cached;
      } finally {
        await equations.close();
        equations.dispose();
        await narration.close();
        narration.dispose();
        await analysis.close();
        analysis.dispose();
        await document.close(discard: true);
        timer.cancel();
        while (sampling) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        await sample();
        report['podoco_handles_before'] = podocoBaseline;
        report['podoco_handles_after'] = podoco_native.podoco_live_handles();
        report['mlsr_handles_before'] = mlsrBaseline;
        report['mlsr_handles_after'] = mlsr_native.mlsr_live_handles();
        await File('${root.path}/native.json')
            .writeAsString(const JsonEncoder.withIndent('  ').convert(report));
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        await PdfrxEntryFunctions.instance.stopBackgroundWorker();
        await temporary.delete(recursive: true);
      }
      expect(podoco_native.podoco_live_handles(), podocoBaseline);
      expect(mlsr_native.mlsr_live_handles(), mlsrBaseline);
    },
    skip: [layout, formula, rules, pdf, output].any((v) => v == null)
        ? 'Set PODOCO_M2_BUNDLE, M6_BUNDLE, M7_RULES, M8_PDF, and M9_OUTPUT for explicit real-model qualification.'
        : false,
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
