import 'dart:ui';

import 'package:pdfrx/pdfrx.dart';

import 'narration_controller.dart';

/// Uses the same page transform as pdfrx selections (including crop/rotation).
void paintNarration(
  Canvas canvas,
  Rect pageRect,
  PdfPage page,
  NarrationController narration,
  Object documentId,
) {
  if (!identical(narration.source?.documentId, documentId) ||
      narration.terminal) {
    return;
  }
  final state = narration.snapshot;
  final passage = narration.source?.passage;
  if (state?.start == null || state?.end == null || passage == null) return;
  canvas.save();
  canvas.clipRect(pageRect);
  final paint = Paint()..color = const Color(0x66ffb300);
  for (final rect in passage.rectangles(
    page.pageNumber,
    state!.start!,
    state.end!,
  )) {
    canvas.drawRect(
      rect
          .toRect(page: page, scaledPageSize: pageRect.size)
          .translate(pageRect.left, pageRect.top),
      paint,
    );
  }
  canvas.restore();
}
