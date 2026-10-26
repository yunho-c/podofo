import 'dart:ui';

import 'package:pdfrx/pdfrx.dart';
import 'package:podoco/podoco.dart' as podoco;

import '../services/pdf_session.dart';
import 'analysis_controller.dart';
import 'pdf_analysis_source.dart';

void paintAnalysis(
  Canvas canvas,
  Rect pageRect,
  PdfPage page,
  AnalysisController analysis,
  PdfSession session,
) {
  final result = analysis.visiblePage;
  if (!analysis.showRegions ||
      !identical(analysis.session, session) ||
      session.lease.isClosed ||
      result == null ||
      result.page.key.document != analysisDocumentRef(session) ||
      result.page.key.pageIndex != page.pageNumber - 1) {
    return;
  }
  canvas.save();
  canvas.clipRect(pageRect);
  for (final region in result.regions) {
    final color = region.category == podoco.RegionCategory.formula
        ? const Color(0xffdf7b25)
        : const Color(0xff2989ca);
    canvas.drawRect(
      analysisRect(region.bounds, result.page.space, pageRect),
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }
  canvas.restore();
}
