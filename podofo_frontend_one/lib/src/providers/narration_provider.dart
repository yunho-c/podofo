import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../narration/mlsr_narrator.dart';
import '../narration/narration_controller.dart';
import '../narration/narrator.dart';
import 'user_state_provider.dart';
import 'data_provider.dart';
import '../services/narration_bookmarks.dart';
import '../services/pdf_session.dart';

final narrationBookmarksProvider = Provider<NarrationBookmarks>(
  (ref) => NarrationBookmarks(ref.watch(objectboxProvider).store),
);

/// Stable app ownership. UI widgets listen narrowly with ListenableBuilder.
final narrationControllerProvider = Provider<NarrationController>((ref) {
  final controller = NarrationController(
    open: MlsrNarrator.open,
    unavailableReason: narrationUnavailableReason(),
    onPosition: (source, anchor) {
      final session = source.documentId;
      if (session is PdfSession) {
        ref.read(narrationBookmarksProvider).save(session.path, anchor);
      }
    },
  );
  final preferences = ref.read(userStateNotifierProvider);
  controller.settings = NarrationSettings(
    voice: preferences.audioVoice ?? '',
    language: preferences.audioLanguage,
    speed: normalizedNarrationSpeed(preferences.audioSpeed),
  );
  ref.onDispose(controller.dispose);
  return controller;
});
