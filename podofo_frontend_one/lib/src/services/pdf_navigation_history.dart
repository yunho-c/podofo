import 'package:flutter/widgets.dart';
import 'package:pdfrx/pdfrx.dart';

/// A reading position relative to a page, independent of the window's size.
class PdfReadingPosition {
  PdfReadingPosition._(this.pageIndex, this.point, this.zoom);

  factory PdfReadingPosition.capture(PdfViewerController viewer) {
    final center = viewer.visibleRect.center;
    final pages = viewer.layout.pageLayouts;
    var nearest = 0;
    var distance = double.infinity;
    for (var i = 0; i < pages.length; i++) {
      final page = pages[i];
      final clamped = Offset(
        center.dx.clamp(page.left, page.right),
        center.dy.clamp(page.top, page.bottom),
      );
      final candidate = (center - clamped).distanceSquared;
      if (candidate < distance) {
        nearest = i;
        distance = candidate;
      }
    }
    final page = pages[nearest];
    return PdfReadingPosition._(
      nearest,
      Offset(
        (center.dx - page.left) / page.width,
        (center.dy - page.top) / page.height,
      ),
      viewer.currentZoom,
    );
  }

  final int pageIndex;
  final Offset point;
  final double zoom;

  Matrix4 matrixFor(PdfViewerController viewer) {
    final page = viewer.layout.pageLayouts[pageIndex];
    return viewer.calcMatrixFor(
      page.topLeft + Offset(point.dx * page.width, point.dy * page.height),
      zoom: zoom,
    );
  }
}

/// Transient history belongs to an open session, including across tab/Save As
/// changes. It is intentionally neither persisted nor shared with other PDFs.
class PdfNavigationHistory {
  final _positions = <PdfReadingPosition>[];
  PdfReadingPosition? get previous => _positions.lastOrNull;

  void remember(PdfReadingPosition position) {
    _positions.add(position);
    if (_positions.length > 100) _positions.removeAt(0);
  }

  void returnedTo(PdfReadingPosition position) {
    if (identical(previous, position)) _positions.removeLast();
  }
}
