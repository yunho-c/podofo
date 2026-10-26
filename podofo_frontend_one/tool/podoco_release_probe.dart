// Instrumented entrypoint support, never invoked by the ordinary app.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:podoco/podoco.dart' as podoco;
import 'package:podoco_flutter/podoco_flutter.dart';
import 'package:podoco_app_models/app_models.dart';
// Diagnostic accounting only; inference uses the public SDK.
// ignore: implementation_imports
import 'package:podoco/src/bindings.g.dart' as podoco_native;
// ignore: implementation_imports
import 'package:mlsr/src/bindings.g.dart' as mlsr_native;
import 'package:podofo_one/src/analysis/analysis_controller.dart';
import 'package:podofo_one/src/analysis/analysis_engine.dart';
import 'package:podofo_one/src/analysis/analysis_store.dart';
import 'package:podofo_one/src/analysis/equation_controller.dart';
import 'package:podofo_one/src/analysis/math_speech_engine.dart';
import 'package:podofo_one/src/narration/mlsr_narrator.dart';
import 'package:podofo_one/src/narration/narration_controller.dart';
import 'package:podofo_one/src/narration/narrator.dart';
import 'package:podofo_one/src/services/pdf_session.dart';

void require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> runProbe(Uint8List pdfBytes) async {
  WidgetsFlutterBinding.ensureInitialized();
  stdout.writeln('PODOCO_PROBE_PID=$pid');
  runApp(
    const MaterialApp(
      home: Scaffold(
        body: Center(
          child: Text('PoDoFo bundled analysis qualification is running.'),
        ),
      ),
    ),
  );
  final report = <String, Object?>{
    'passed': false,
    'executable': Platform.resolvedExecutable,
    'pdf_sha256': sha256.convert(pdfBytes).toString(),
    'audio_volume': 0,
    'human_listening': false,
    'model_path_arguments': false,
    'timing_boundary': 'single active-host correctness run, including cold model initialization',
  };
  final clock = Stopwatch()..start();
  final marks = <String, int>{};
  void stage(String value) {
    marks[value] = clock.elapsedMilliseconds;
    stdout.writeln('PODOCO_PROBE_STAGE=$value');
  }

  AnalysisController? analysis;
  EquationController? equations;
  NarrationController? narration;
  PdfSession? document;
  final baseline = podoco_native.podoco_live_handles();
  final audioBaseline = mlsr_native.mlsr_live_handles();
  try {
    stage('sandbox');
    final denied = <String>[];
    final forbidden = jsonDecode(
      Platform.environment['PODOCO_FORBIDDEN_FILES'] ?? '[]',
    ) as List;
    require(forbidden.isNotEmpty, 'Missing developer-source denial checks');
    for (final path in forbidden.cast<String>()) {
      try {
        final file = await File(path).open();
        await file.close();
      } on FileSystemException catch (error) {
        require(
          [1, 13].contains(error.osError?.errorCode),
          'Expected permission denial: $error',
        );
        denied.add(path);
        continue;
      }
      throw StateError('Sandbox can read developer input: $path');
    }
    report['denied_developer_inputs'] = denied;
    try {
      final socket = await Socket.connect(
        '127.0.0.1',
        int.parse(Platform.environment['PODOCO_DENIED_NETWORK_PORT']!),
        timeout: const Duration(seconds: 3),
      );
      socket.destroy();
      throw StateError('Probe unexpectedly has network access');
    } on SocketException catch (error) {
      require(
        [1, 13].contains(error.osError?.errorCode),
        'Expected network permission denial: $error',
      );
      report['network_denied'] = true;
    }
    stage('resource discovery');
    final located = await const FlutterModelLoader().locatePack(
      AppAnalysisPacks.documentAnalysis,
    );
    final bundle = File(Platform.resolvedExecutable).parent.parent.parent
        .resolveSymbolicLinksSync();
    require(
      located.directory.startsWith('$bundle/'),
      'Models escaped relocated app',
    );
    report['resources'] = located.directory;
    report['manifest_hashes'] = located.manifestHashes;
    final support = await getApplicationSupportDirectory();
    await support.create(recursive: true);
    final evidence = await support.createTemp('podoco-bundled-');
    report['fresh_workspace'] = evidence.path;
    await pdfrxInitialize(tmpPath: (await getTemporaryDirectory()).path);
    final pdf = await File('${evidence.path}/input.pdf').writeAsBytes(pdfBytes);
    document = await PdfSession.open(pdf.path);
    var analysisOpens = 0, mathOpens = 0;
    final progress = <String>[];
    analysis = AnalysisController(
      store: AnalysisStore(Directory('${evidence.path}/pages')),
      openBundled: (notify) {
        analysisOpens++;
        return NativeAnalysisEngine.openBundled((value) {
          progress.add(value);
          notify(value);
        });
      },
    )..select(document, 0);
    narration = NarrationController(
      open: (progress) => MlsrNarrator.open(progress, volume: 0),
    );
    final copies = <String>[];
    equations = EquationController(
      analysis: analysis,
      narration: narration,
      openBundled: (notify) {
        mathOpens++;
        return NativeMathSpeechEngine.openBundled((value) {
          progress.add(value);
          notify(value);
        });
      },
      // Capture the exact Copy payload without replacing the user's clipboard.
      copy: (text) async => copies.add(text),
    );
    require(
      analysisOpens == 0 && mathOpens == 0,
      'Initialization was not lazy',
    );
    stage('analyze');
    final work = analysis.analyze();
    require(
      identical(work, analysis.analyze()),
      'Repeated Analyze did not coalesce',
    );
    await work.timeout(const Duration(minutes: 5));
    require(analysis.error == null, 'Analysis failed: ${analysis.error}');
    require(
      analysis.outcome?.status == podoco.CompletionStatus.completed,
      'Analysis incomplete',
    );
    require(
      analysis.outcome!.progress.processed.formulasRecognized == 8,
      'Expected eight recognized formulas',
    );
    require(
      analysis.modelPaths == null && analysisOpens == 1 && mathOpens == 0,
      'Unexpected model initialization',
    );
    report['page'] = analysis.visibleSnapshot!.toJson();
    stage('copy');
    final first = analysis.visiblePage!.formulas.firstWhere(
      (f) =>
          f.state is podoco.FormulaFinishedState &&
          (f.state as podoco.FormulaFinishedState).outcome
              is podoco.FormulaRecognized,
    );
    equations.select(first.regionId);
    await equations.copyLatex();
    require(copies.single == 'A_{m-1}', 'Copy differs: $copies');
    require(mathOpens == 0, 'Copy initialized math rules');
    report['copied_latex'] = copies.single;
    stage('listen');
    final listening = equations.listen();
    require(
      identical(listening, equations.listen()),
      'Repeated Listen did not coalesce',
    );
    await listening.timeout(const Duration(minutes: 3));
    require(
      equations.error == null && narration.error == null,
      'Speech failed: ${equations.error ?? narration.error}',
    );
    require(
      equations.lastSpeechText == 'cap a sub m minus 1 end sub',
      'Unexpected MathCAT output: ${equations.lastSpeechText}',
    );
    final deadline = DateTime.now().add(const Duration(minutes: 2));
    while (narration.snapshot?.phase != NarrationPhase.completed) {
      require(DateTime.now().isBefore(deadline), 'Playback timeout');
      require(narration.error == null, 'Playback failed: ${narration.error}');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    require(
      (narration.snapshot?.positionFrames ?? 0) > 2048,
      'No audio progression',
    );
    report['audio_frames'] = narration.snapshot!.positionFrames;
    report['spoken_text'] = equations.lastSpeechText;
    report['analysis_opens'] = analysisOpens;
    report['math_opens'] = mathOpens;
    report['preparation_messages'] = progress;
    require(
      equations.rulesDirectory == null && mathOpens == 1,
      'Math required an override',
    );
    report['passed'] = true;
  } catch (error, stack) {
    report['error'] = '$error';
    report['stack'] = '$stack';
  } finally {
    stage('cleanup');
    try {
      await equations?.close();
      await narration?.close();
      await analysis?.close();
      await document?.close(discard: true);
      await PdfrxEntryFunctions.instance.stopBackgroundWorker();
    } catch (error) {
      report['cleanup_error'] = '$error';
      report['passed'] = false;
    }
    report['podoco_handles_after'] = podoco_native.podoco_live_handles();
    report['mlsr_handles_after'] = mlsr_native.mlsr_live_handles();
    if (report['podoco_handles_after'] != baseline ||
        report['mlsr_handles_after'] != audioBaseline) {
      report['passed'] = false;
    }
    report['marks_ms'] = marks;
    stdout.writeln('PODOCO_PROBE_REPORT=${jsonEncode(report)}');
    await stdout.flush();
  }
  exit(report['passed'] == true ? 0 : 1);
}
