import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../analysis/analysis_controller.dart';
import '../analysis/analysis_engine.dart';
import '../analysis/math_speech_engine.dart';
import '../analysis/analysis_store.dart';
import '../analysis/equation_controller.dart';
import 'document_provider.dart';
import 'narration_provider.dart';

final equationControllerProvider = Provider<EquationController?>((ref) {
  final analysis = ref.watch(analysisControllerProvider).asData?.value;
  if (analysis == null) return null;
  final controller = EquationController(
    analysis: analysis,
    narration: ref.read(narrationControllerProvider),
    openBundled: NativeMathSpeechEngine.openBundled,
  );
  ref.onDispose(controller.dispose);
  return controller;
});

final analysisControllerProvider = FutureProvider<AnalysisController>((
  ref,
) async {
  final root = await getApplicationSupportDirectory();
  final controller = AnalysisController(
    store: AnalysisStore(Directory(p.join(root.path, 'podoco', 'pages-v2'))),
    openBundled: NativeAnalysisEngine.openBundled,
  );
  if (!ref.mounted) {
    controller.dispose();
    throw StateError('Reader is closed');
  }
  ref.onDispose(controller.dispose);
  ref.listen(currentDocumentProvider, (_, document) {
    controller.select(document?.session, (document?.lastOpenedPage ?? 1) - 1);
  }, fireImmediately: true);
  return controller;
}, retry: (_, _) => null);
