import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:podofo_one/src/analysis/analysis_controller.dart';
import 'package:podofo_one/src/analysis/analysis_store.dart';
import 'package:podofo_one/src/analysis/equation_controller.dart';
import 'package:podofo_one/src/analysis/pdf_analysis_source.dart';
import 'package:podofo_one/src/narration/narration_controller.dart';
import 'package:podofo_one/src/services/pdf_session.dart';

import 'analysis_native_test.dart' show ControlledEngine;
import 'equation_controller_test.dart' show FakeMath, PublishingAnalysis;
import 'fixtures/analysis_fixture.dart';
import 'fixtures/pdf_fixture.dart';
import 'support/fake_narrator.dart';
import 'support/file_access_mock.dart';

class LazyEngine extends ControlledEngine {
  @override
  Future<void> close() async {
    closeCount++;
    if (started.isCompleted) job.finish();
  }
}

Future<void> until(bool Function() ready) async {
  final end = DateTime.now().add(const Duration(seconds: 5));
  while (!ready()) {
    if (DateTime.now().isAfter(end)) {
      fail('Timed out waiting for controlled initialization');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporary;
  late PdfSession document;
  setUpAll(() async {
    installFileAccessMock();
    temporary = await Directory.systemTemp.createTemp('podoco-bundled-');
    await pdfrxInitialize(tmpPath: temporary.path);
    final file = File('${temporary.path}/input.pdf');
    await file.writeAsBytes(pdfFixture());
    document = await PdfSession.open(file.path);
  });
  tearDownAll(() async {
    await document.close(discard: true);
    await PdfrxEntryFunctions.instance.stopBackgroundWorker();
    await temporary.delete(recursive: true);
  });

  test(
    'analysis is lazy, coalesces startup, and cancels before rendering',
    () async {
      final gate = Completer<LazyEngine>();
      final engine = LazyEngine();
      var opens = 0;
      final analysis = AnalysisController(
        store: AnalysisStore(temporary),
        openBundled: (progress) {
          opens++;
          progress('Verifying bundled assets…');
          return gate.future;
        },
      )..select(document, 0);
      try {
        expect(opens, 0);
        expect(analysis.canAnalyze, isTrue);
        final first = analysis.analyze();
        expect(analysis.analyze(), same(first));
        await until(() => opens == 1);
        expect(analysis.preparation, contains('Verifying'));
        analysis.cancel();
        gate.complete(engine);
        await first;
        expect(engine.started.isCompleted, isFalse);
        expect(analysis.ready, isTrue);
        final next = analysis.analyze();
        await engine.started.future;
        engine.job.finish();
        await next;
        expect(opens, 1);
      } finally {
        await analysis.close();
        analysis.dispose();
      }
      expect(engine.closeCount, 1);
    },
  );

  test('document replacement suppresses late analysis and close releases a late engine', () async {
    for (final close in [false, true]) {
      final gate = Completer<LazyEngine>(), engine = LazyEngine();
      var opening = false;
      final analysis = AnalysisController(
        store: AnalysisStore(temporary),
        openBundled: (_) {
          opening = true;
          return gate.future;
        },
      )..select(document, 0);
      final work = analysis.analyze();
      await until(() => opening);
      if (!close) analysis.select(null, 0);
      final closing = close ? analysis.close() : null;
      gate.complete(engine);
      await work;
      await closing;
      expect(engine.started.isCompleted, isFalse);
      await analysis.close();
      analysis.dispose();
      expect(engine.closeCount, 1);
    }
  });

  test('failed bundled open retries explicitly and returning from override stays lazy', () async {
    var opens = 0;
    final engine = LazyEngine(), custom = LazyEngine();
    final analysis = AnalysisController(
      store: AnalysisStore(temporary),
      open: (_) async => custom,
      openBundled: (_) async {
        if (++opens == 1) throw StateError('missing bundled payload');
        return engine;
      },
    )..select(document, 0);
    try {
      await analysis.analyze();
      expect(analysis.error, contains('missing bundled payload'));
      expect(analysis.running, isFalse);
      await analysis.configure('custom');
      expect(analysis.usingBundledModels, isFalse);
      await analysis.useBundledModels();
      expect(custom.closeCount, 1);
      expect(opens, 1);
      expect(analysis.usingBundledModels, isTrue);
      final work = analysis.analyze();
      await engine.started.future;
      engine.job.finish();
      await work;
      expect(opens, 2);
    } finally {
      await analysis.close();
      analysis.dispose();
    }
  });

  for (final scenario in [
    'coalesce',
    'newer prose',
    'missing rules',
    'close',
  ]) {
    test('bundled math preparation: $scenario', () async {
      final analysis = PublishingAnalysis(temporary)..select(document, 0);
      final audio = FakeNarratorSession();
      final narration = NarrationController(open: (_) async => audio);
      final gate = Completer<FakeMath>();
      final math = FakeMath();
      final copied = <String>[];
      var opens = 0;
      final equations = EquationController(
        analysis: analysis,
        narration: narration,
        openBundled: (progress) {
          opens++;
          progress('Preparing speech…');
          return gate.future;
        },
        copy: (text) async => copied.add(text),
      );
      analysis.publish(formulaFixture(analysisDocumentRef(document), stage: 2));
      equations.select(17);
      try {
        await equations.copyLatex();
        expect(opens, 0);
        final work = equations.listen();
        expect(equations.listen(), same(work));
        await until(() => opens == 1);
        Future<void>? closing;
        if (scenario == 'newer prose') {
          await narration.read(
            document,
            () async => NarrationSource(
              documentId: document,
              title: 'New prose',
              text: 'New prose.',
            ),
          );
        } else if (scenario == 'close') {
          closing = equations.close();
        }
        if (scenario == 'missing rules') {
          gate.completeError(StateError('missing bundled math rules'));
        } else {
          gate.complete(math);
        }
        await work;
        await closing;
        if (scenario == 'coalesce') {
          expect(audio.texts, ['spoken en ClearSpeak']);
          expect(equations.error, isNull);
        } else if (scenario == 'newer prose') {
          expect(audio.texts, ['New prose.']);
          expect(narration.source?.text, 'New prose.');
        } else {
          expect(audio.texts, isEmpty);
          if (scenario == 'missing rules') {
            expect(equations.error, contains('missing bundled math rules'));
            await equations.copyLatex();
            expect(copied, hasLength(2));
          }
        }
      } finally {
        await equations.close();
        equations.dispose();
        await narration.close();
        narration.dispose();
        await analysis.close();
        analysis.dispose();
      }
      if (scenario != 'missing rules') expect(math.closes, 1);
    });
  }
}
