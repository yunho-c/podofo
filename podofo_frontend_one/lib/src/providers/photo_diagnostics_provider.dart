import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../dark_mode/photo_diagnostics.dart';
import '../dark_mode/photo_quality.dart';
import '../services/pdf_session.dart';

// Developer diagnostics are temporary, independent of persisted appearance.
final photoQualityProvider = StateProvider<PhotoQuality>(
  (ref) => const PhotoQuality(),
);
final showPhotoDiagnosticsProvider = StateProvider<bool>((ref) => false);
final includeTranslucentPhotoPixelsProvider = StateProvider<bool>(
  (ref) => false,
);
final photoDiagnosticsProvider = Provider.autoDispose
    .family<PhotoDiagnosticsController, PdfSession>((ref, session) {
      final controller = PhotoDiagnosticsController();
      ref.onDispose(controller.dispose);
      return controller;
    });
