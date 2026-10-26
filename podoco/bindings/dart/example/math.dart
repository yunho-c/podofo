import 'dart:convert';
import 'dart:io';

import 'package:podoco/podoco.dart';

/// JSONL corpus runner with explicit per-expression language/style/context.
Future<void> main(List<String> args) async {
  if (args.length != 2) {
    throw ArgumentError('Usage: math.dart RULES INPUT.jsonl');
  }
  final processor = await MathProcessor.open(await MathRules.verify(args[0]));
  try {
    await for (final line in File(
      args[1],
    ).openRead().transform(utf8.decoder).transform(const LineSplitter())) {
      final row = jsonDecode(line) as Map<String, dynamic>;
      final source = row['input'] as Map<String, dynamic>;
      final display = FormulaDisplayKind.values.byName(
        source['display_kind'] as String,
      );
      final input = source['format'] == 'latex'
          ? MathInput.latex(source['text'] as String, displayKind: display)
          : MathInput.mathml(source['text'] as String, displayKind: display);
      try {
        final result = await processor.toSpeech(
          input,
          MathSpeechOptions.fromJson(
            Map<String, Object?>.from(row['options'] as Map),
          ),
        );
        stdout.writeln(jsonEncode({'id': row['id'], 'value': result.toJson()}));
      } on PodocoException catch (error) {
        stdout.writeln(jsonEncode({'id': row['id'], 'error': error.toJson()}));
      }
    }
  } finally {
    await processor.dispose();
  }
  if (nativeLiveHandles != 0) throw StateError('Leaked native handles');
}
