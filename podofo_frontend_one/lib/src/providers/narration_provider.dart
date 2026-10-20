import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../narration/mlsr_narrator.dart';
import '../narration/narration_controller.dart';
import '../narration/narrator.dart';
import 'user_state_provider.dart';

/// Stable app ownership. UI widgets listen narrowly with ListenableBuilder.
final narrationControllerProvider = Provider<NarrationController>((ref) {
  final controller = NarrationController(
    open: MlsrNarrator.open,
    unavailableReason: narrationUnavailableReason(),
  );
  final preferences = ref.read(userStateNotifierProvider);
  controller.settings = NarrationSettings(
    voice: preferences.audioVoice ?? '',
    speed: preferences.audioSpeed.isFinite
        ? preferences.audioSpeed.clamp(0.5, 2.0)
        : 1,
  );
  ref.onDispose(controller.dispose);
  return controller;
});
