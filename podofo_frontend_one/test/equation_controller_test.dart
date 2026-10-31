import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:podoco/podoco.dart' as podoco;
import 'package:podofo_one/src/analysis/analysis_controller.dart';
import 'package:podofo_one/src/analysis/analysis_store.dart';
import 'package:podofo_one/src/analysis/equation_controller.dart';
import 'package:podofo_one/src/analysis/math_speech_engine.dart';
import 'package:podofo_one/src/analysis/pdf_analysis_source.dart';
import 'package:podofo_one/src/narration/narration_controller.dart';
import 'package:podofo_one/src/narration/narrator.dart';
import 'package:podofo_one/src/services/pdf_session.dart';

import 'fixtures/analysis_fixture.dart';
import 'fixtures/pdf_fixture.dart';
import 'support/fake_narrator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporary;
  late PdfSession document;
  late PublishingAnalysis analysis;
  late FakeMath math;
  late FakeNarratorSession audio;
  late NarrationController narrator;
  late EquationController equations;
  late List<String> copied;
  var counter = 0;
  setUpAll(() async {
    temporary = await Directory.systemTemp.createTemp('podoco-equations-');
    await pdfrxInitialize(tmpPath: temporary.path);
  });
  tearDownAll(() async {
    await PdfrxEntryFunctions.instance.stopBackgroundWorker();
    await temporary.delete(recursive: true);
  });
  setUp(() async {
    final file = File('${temporary.path}/${counter++}.pdf');
    await file.writeAsBytes(pdfFixture());
    document = await PdfSession.open(file.path);
    analysis = PublishingAnalysis(temporary)..select(document, 0);
    audio = FakeNarratorSession();
    narrator = NarrationController(open: (_) async => audio);
    math = FakeMath();
    copied = [];
    equations = EquationController(
      analysis: analysis,
      narration: narrator,
      open: (_) async => math,
      copy: (text) async => copied.add(text),
    );
    await equations.configureRules('rules');
    analysis.publish(formulaFixture(analysisDocumentRef(document), stage: 2));
    equations.select(17);
  });
  tearDown(() async {
    await equations.close();
    equations.dispose();
    await narrator.close();
    narrator.dispose();
    await analysis.close();
    analysis.dispose();
    await document.close(discard: true);
  });

  test(
    'Copy preserves LaTeX exactly and works after conversion failure',
    () async {
      const latex = r'\unsupported{  x + 1 }';
      analysis.publish(
        formulaFixture(analysisDocumentRef(document), stage: 2, latex: latex),
      );
      math.failure = StateError('Unsupported math');
      await equations.listen();
      expect(equations.error, contains('Unsupported math'));
      expect(audio.texts, isEmpty);
      expect(equations.selected!.recognized!.latex, latex);
      await equations.copyLatex();
      expect(copied, [latex]);
      expect(math.calls, 1);
    },
  );

  test('pending selection becomes usable before the final page', () async {
    analysis.publish(formulaFixture(analysisDocumentRef(document)));
    expect(equations.selected!.recognized, isNull);
    await expectLater(equations.copyLatex(), throwsStateError);
    expect(equations.listen, throwsStateError);
    analysis.publish(formulaFixture(analysisDocumentRef(document), stage: 1));
    expect(analysis.pageComplete, false);
    await equations.copyLatex();
    await equations.listen();
    expect(copied.single, r'\frac{x+1}{2}');
    expect(audio.texts, ['spoken en ClearSpeak']);
  });

  test('duplicate Listen shares conversion; repeated cached playback stays bounded', () async {
    final gate = Completer<EquationSpeechText>();
    math.gate = gate;
    final first = equations.listen(), duplicate = equations.listen();
    expect(duplicate, same(first));
    expect(math.calls, 1);
    gate.complete(EquationSpeechText('x plus one over two'));
    await first;
    final bytes = equations.cachedBytes;
    expect(audio.texts, hasLength(1));
    for (var i = 0; i < 20; i++) {
      await narrator.stop();
      await equations.listen();
      expect(equations.cachedBytes, bytes);
    }
    expect(math.calls, 1);
    expect(audio.texts, hasLength(21));
    expect(audio.playbacks.take(20).every((p) => p.disposed), true);
  });

  test('Stop during conversion permits a new Listen and rejects the late first result', () async {
    final old = Completer<EquationSpeechText>();
    math.gate = old;
    final first = equations.listen();
    await narrator.stop();
    math.gate = null;
    await equations.listen();
    old.complete(EquationSpeechText('stale conversion'));
    await first;
    expect(math.calls, 2);
    expect(audio.texts, ['spoken en ClearSpeak']);
    expect(equations.lastSpeechText, 'spoken en ClearSpeak');
  });

  test('document switch cancels only this equation, not newer prose', () async {
    await equations.listen();
    expect(equations.ownsNarration, true);
    final equationAudio = audio.playbacks.single;
    await narrator.read(
      document,
      () async => NarrationSource(
        documentId: document,
        title: 'Prose',
        text: 'New prose request.',
      ),
    );
    expect(equationAudio.cancelled, true);
    final prose = audio.playbacks.last;
    analysis.select(null, 0);
    expect(equations.selected, isNull);
    expect(prose.cancelled, false);
    expect(narrator.source!.text, 'New prose request.');
    await equations.close();
    expect(prose.cancelled, false);
  });

  test(
    'selection changes while conversion is pending suppress late audio',
    () async {
      final gate = Completer<EquationSpeechText>();
      math.gate = gate;
      final work = equations.listen();
      analysis.select(document, 1);
      gate.complete(EquationSpeechText('late'));
      await work;
      expect(audio.texts, isEmpty);
      expect(equations.selected, isNull);
      expect(equations.lastSpeechText, isNull);
      expect(narrator.source, isNull);
    },
  );

  test(
    'revision refresh dismisses selected equation and blocks stale Copy',
    () async {
      await equations.listen();
      final playing = audio.playbacks.single;
      document.revision++;
      analysis.select(document, 0);
      expect(playing.cancelled, true);
      expect(equations.selected, isNull);
      await expectLater(equations.copyLatex(), throwsStateError);
      expect(narrator.source, isNull);
    },
  );

  test(
    'closed PDF cannot produce late speech even without another page event',
    () async {
      final gate = Completer<EquationSpeechText>();
      math.gate = gate;
      final work = equations.listen();
      await document.close();
      gate.complete(EquationSpeechText('late'));
      await work;
      expect(audio.texts, isEmpty);
      expect(equations.selected, isNull);
    },
  );

  test('language changes cancel old speech; style and language each key conversion', () async {
    await equations.listen();
    final first = audio.playbacks.single;
    await narrator.configure(const NarrationSettings(language: 'es'));
    expect(first.cancelled, true);
    expect(narrator.source, isNull);
    await equations.listen();
    expect(math.options.last.language, 'es');
    expect(audio.texts.last, 'spoken es ClearSpeak');
    equations.setSpeechStyle('SimpleSpeak');
    expect(audio.playbacks.last.cancelled, true);
    await equations.listen();
    expect(math.calls, 3);
    expect(audio.texts.last, 'spoken es SimpleSpeak');
    await narrator.configure(const NarrationSettings(language: 'fr-CA'));
    await equations.listen();
    expect(equations.error, contains('does not support'));
    expect(math.calls, 3);
    await equations.copyLatex();
    expect(copied, hasLength(1));
  });

  test(
    'voice and speed changes reuse text and preserve equation ownership',
    () async {
      await equations.listen();
      await narrator.configure(
        const NarrationSettings(voice: 'supertonic3:M1', speed: 1.2),
      );
      expect(math.calls, 1);
      expect(equations.ownsNarration, true);
      expect(audio.requests.last.speed, 1.2);
      analysis.select(null, 0);
      expect(audio.playbacks.last.cancelled, true);
    },
  );

  test(
    'cache evicts old expressions and rules reconfiguration clears it',
    () async {
      for (var i = 0; i < 260; i++) {
        await narrator.stop();
        analysis.publish(
          formulaFixture(
            analysisDocumentRef(document),
            stage: 2,
            latex: 'x+$i',
          ),
        );
        await equations.listen();
      }
      expect(math.calls, 260);
      expect(equations.cachedBytes, lessThanOrEqualTo(4 * 1024 * 1024));
      await narrator.stop();
      analysis.publish(
        formulaFixture(analysisDocumentRef(document), stage: 2, latex: 'x+0'),
      );
      await equations.listen();
      expect(math.calls, 261);
      await equations.configureRules('new-rules');
      expect(equations.cachedBytes, 0);
      expect(math.closes, 1);
      expect(audio.playbacks.last.cancelled, true);
    },
  );

  test(
    'closing while rules open drains the late engine exactly once',
    () async {
      await equations.close();
      final gate = Completer<MathSpeechEngine>();
      final next = FakeMath();
      final controller = EquationController(
        analysis: analysis,
        narration: narrator,
        open: (_) => gate.future,
      );
      final opening = controller.configureRules('late-rules');
      final closing = controller.close();
      gate.complete(next);
      await Future.wait([opening, closing]);
      expect(next.closes, 1);
      expect(controller.ready, false);
      controller.dispose();
    },
  );
}

class PublishingAnalysis extends AnalysisController {
  PublishingAnalysis(Directory temporary)
    : super(store: AnalysisStore(Directory('${temporary.path}/cache')));
  void publish(podoco.AnalysisUpdate update) {
    visibleSnapshot = update is podoco.FormulaFinished
        ? visibleSnapshot!.merge(update)
        : AnalysisPageSnapshot.fromUpdate(update);
    notifyListeners();
  }
}

class FakeMath implements MathSpeechEngine {
  int calls = 0, closes = 0;
  Object? failure;
  Completer<EquationSpeechText>? gate;
  final options = <podoco.MathSpeechOptions>[];
  @override
  String get identity => 'fixture-rules';
  @override
  List<String> stylesFor(String language) =>
      ['en', 'es'].contains(language) ? ['ClearSpeak', 'SimpleSpeak'] : [];
  @override
  Future<EquationSpeechText> convert(
    podoco.RecognizedFormula formula,
    podoco.MathSpeechOptions options,
  ) async {
    calls++;
    this.options.add(options);
    if (failure != null) throw failure!;
    return gate == null
        ? EquationSpeechText(
            'spoken ${options.language} ${options.speechStyle}',
          )
        : await gate!.future;
  }

  @override
  Future<void> close() async {
    closes++;
  }
}
