import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../narration/mlsr_narrator.dart';
import '../narration/narration_controller.dart';

/// Stable app ownership. UI widgets listen narrowly with ListenableBuilder.
final narrationControllerProvider = Provider<NarrationController>((ref) {
  final controller = NarrationController(
    open: MlsrNarrator.open,
    unavailableReason: narrationUnavailableReason(),
  );
  ref.onDispose(controller.dispose);
  return controller;
});
