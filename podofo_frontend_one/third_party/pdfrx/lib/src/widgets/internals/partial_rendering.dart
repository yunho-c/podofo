import 'dart:ui';

typedef PixelAlignedViewport = ({int width, int height, Rect paintRect, double pageLeft, double pageTop});

/// Round the tile boundary outwards on the physical screen grid, preserving the
/// fractional page origin inside it. Do not round the PDF-to-pixel transform.
PixelAlignedViewport? pixelAlignedViewport({
  required Rect pageRect,
  required Rect visibleRect,
  required Offset pageOriginPhysical,
  required double scale,
}) {
  if (!scale.isFinite ||
      scale <= 0 ||
      !pageRect.isFinite ||
      !visibleRect.isFinite ||
      !pageOriginPhysical.dx.isFinite ||
      !pageOriginPhysical.dy.isFinite ||
      visibleRect.isEmpty) {
    return null;
  }
  // Arithmetic through a viewport inverse can leave integral edges 1 ulp away.
  double stable(double v) => (v - v.roundToDouble()).abs() < 1e-7 ? v.roundToDouble() : v;
  final x1 = pageOriginPhysical.dx + (visibleRect.left - pageRect.left) * scale;
  final y1 = pageOriginPhysical.dy + (visibleRect.top - pageRect.top) * scale;
  final x2 = pageOriginPhysical.dx + (visibleRect.right - pageRect.left) * scale;
  final y2 = pageOriginPhysical.dy + (visibleRect.bottom - pageRect.top) * scale;
  if (!x1.isFinite || !y1.isFinite || !x2.isFinite || !y2.isFinite) return null;
  final left = stable(x1).floor(), top = stable(y1).floor();
  final right = stable(x2).ceil(), bottom = stable(y2).ceil();
  if (right <= left || bottom <= top) return null;
  return (
    width: right - left,
    height: bottom - top,
    paintRect: Rect.fromLTWH(
      pageRect.left + (left - pageOriginPhysical.dx) / scale,
      pageRect.top + (top - pageOriginPhysical.dy) / scale,
      (right - left) / scale,
      (bottom - top) / scale,
    ),
    pageLeft: pageOriginPhysical.dx - left,
    pageTop: pageOriginPhysical.dy - top,
  );
}

/// Converts a logical page rectangle to integer render coordinates, or returns null for invalid input.
({int x, int y, int width, int height})? scaleRectForRendering(Rect rect, double scale) {
  if (!scale.isFinite || scale <= 0 || !rect.isFinite) return null;
  final left = rect.left * scale;
  final top = rect.top * scale;
  final width = rect.width * scale;
  final height = rect.height * scale;
  if (!left.isFinite || !top.isFinite || !width.isFinite || !height.isFinite) return null;
  return (x: left.toInt(), y: top.toInt(), width: width.toInt(), height: height.toInt());
}
