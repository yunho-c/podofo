import 'dart:convert';

import 'package:podoco/podoco.dart' as podoco;
import 'package:podoco_flutter/podoco_flutter.dart';
import 'package:podoco_app_models/app_models.dart';

import 'analysis_engine.dart' show analysisPreparationText;

class EquationSpeechText {
  EquationSpeechText(
    this.text, {
    List<String> diagnostics = const [],
    Map<String, Object?> provenance = const {},
  }) : diagnostics = List.unmodifiable(diagnostics),
       provenance = Map.unmodifiable(provenance);
  final String text;
  final List<String> diagnostics;
  final Map<String, Object?> provenance;
  int get retainedBytes =>
      utf8.encode(jsonEncode([text, diagnostics, provenance])).length;
}

abstract interface class MathSpeechEngine {
  String get identity;
  List<String> stylesFor(String language);
  Future<EquationSpeechText> convert(
    podoco.RecognizedFormula formula,
    podoco.MathSpeechOptions options,
  );
  Future<void> close();
}

class NativeMathSpeechEngine implements MathSpeechEngine {
  NativeMathSpeechEngine._(this._processor);
  final podoco.MathProcessor _processor;
  static Future<MathSpeechEngine> openBundled(
    void Function(String) progress,
  ) async => NativeMathSpeechEngine._(
    await FlutterPodoco.openMathProcessor(
      pack: AppAnalysisPacks.documentAnalysis,
      onProgress: (value) => progress(analysisPreparationText(value)),
    ),
  );
  static Future<MathSpeechEngine> open(String directory) async =>
      NativeMathSpeechEngine._(
        await podoco.MathProcessor.open(
          await podoco.MathRules.verify(directory),
        ),
      );
  @override
  String get identity => jsonEncode([
    podoco.nativeVersion,
    _processor.profile,
    _processor.rulesManifestSha256,
  ]);
  @override
  List<String> stylesFor(String language) =>
      _processor.languages
          .where((l) => l.language == language)
          .firstOrNull
          ?.speechStyles ??
      const [];
  @override
  Future<EquationSpeechText> convert(
    podoco.RecognizedFormula formula,
    podoco.MathSpeechOptions options,
  ) async {
    final speech = await _processor.toSpeech(
      podoco.MathInput.latex(formula.latex, displayKind: formula.displayKind),
      options,
    );
    if (speech.provenance.profile != _processor.profile ||
        speech.provenance.rulesManifestSha256 !=
            _processor.rulesManifestSha256) {
      throw StateError('Unexpected math conversion provenance');
    }
    return EquationSpeechText(
      speech.text,
      diagnostics: List.unmodifiable(speech.diagnostics.map((d) => d.message)),
      provenance: Map.unmodifiable(
        Map<String, Object?>.from(speech.toJson()['provenance'] as Map),
      ),
    );
  }

  @override
  Future<void> close() => _processor.dispose();
}
