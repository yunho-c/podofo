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
  if (!identical(narration.source?.documentId, documentId)) {
    return;
  }
  final state = narration.snapshot;
  final previewing = narration.previewingDocument;
  final preview = narration.previewHighlight;
  final passage = previewing ? preview?.passage : narration.source?.passage;
  final start = previewing ? preview?.start : state?.start;
  final end = previewing ? preview?.end : state?.end;
  if ((!previewing && narration.terminal) ||
      start == null ||
      end == null ||
      passage == null) {
    return;
  }
  canvas.save();
  canvas.clipRect(pageRect);
  final paint = Paint()..color = const Color(0x66ffb300);
  for (final rect in passage.rectangles(page.pageNumber, start, end)) {
    canvas.drawRect(
      rect
          .toRect(page: page, scaledPageSize: pageRect.size)
          .translate(pageRect.left, pageRect.top),
      paint,
    );
  }
  canvas.restore();
}
