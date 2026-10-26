import 'dart:ui';

import 'package:pdfrx/pdfrx.dart';
import 'package:podoco/podoco.dart' as podoco;

import '../services/pdf_session.dart';
import 'analysis_controller.dart';
import 'equation_controller.dart';
import 'pdf_analysis_source.dart';

void paintAnalysis(
  Canvas canvas,
  Rect pageRect,
  PdfPage page,
  AnalysisController analysis,
  PdfSession session, {
  EquationSelection? selected,
  bool speaking = false,
}) {
  final result = analysis.visiblePage;
  if (!identical(analysis.session, session) ||
      session.lease.isClosed ||
      result == null ||
      result.page.key.document != analysisDocumentRef(session) ||
      result.page.key.pageIndex != page.pageNumber - 1) {
    return;
  }
  canvas.save();
  canvas.clipRect(pageRect);
  for (final region in result.regions) {
    final isSelected =
        selected?.region.id == region.id &&
        selected?.document == result.page.key.document &&
        selected?.pageIndex == page.pageNumber - 1;
    if (!analysis.showRegions && !isSelected) continue;
    final color = region.category == podoco.RegionCategory.formula
        ? (isSelected && speaking
              ? const Color(0xff7657ca)
              : const Color(0xffdf7b25))
        : const Color(0xff2989ca);
    if (isSelected) {
      canvas.drawRect(
        analysisRect(region.bounds, result.page.space, pageRect),
        Paint()..color = color.withValues(alpha: .16),
      );
    }
    canvas.drawRect(
      analysisRect(region.bounds, result.page.space, pageRect),
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = isSelected ? 2.5 : 1.5,
    );
  }
  canvas.restore();
}
