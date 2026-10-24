import 'dart:math' as math;
import 'dart:ui';

import 'package:pdfrx/pdfrx.dart';

/// Continuous spreads: pages 1–2, 3–4, etc., with an unpaired page centered.
PdfPageLayout layoutTwoPages(List<PdfPage> pages, PdfViewerParams params) {
  final margin = params.margin;
  var width = 0.0;
  for (var i = 0; i < pages.length; i += 2) {
    final right = i + 1 < pages.length ? pages[i + 1] : null;
    width = math.max(
      width,
      pages[i].width + (right == null ? 0 : margin + right.width),
    );
  }
  width += margin * 2;

  final rects = <Rect>[];
  var y = margin;
  for (var i = 0; i < pages.length; i += 2) {
    final left = pages[i];
    final right = i + 1 < pages.length ? pages[i + 1] : null;
    final height = math.max(left.height, right?.height ?? 0);
    final rowWidth = left.width + (right == null ? 0 : margin + right.width);
    final x = (width - rowWidth) / 2;
    rects.add(
      Rect.fromLTWH(x, y + (height - left.height) / 2, left.width, left.height),
    );
    if (right != null) {
      rects.add(
        Rect.fromLTWH(
          x + left.width + margin,
          y + (height - right.height) / 2,
          right.width,
          right.height,
        ),
      );
    }
    y += height + margin;
  }
  return PdfPageLayout(pageLayouts: rects, documentSize: Size(width, y));
}

/// Bounds of the page or spread containing a one-based page number.
Rect pageViewBounds(
  PdfPageLayout layout,
  int pageNumber, {
  required bool twoPages,
}) {
  final index = pageNumber - 1;
  if (!twoPages) return layout.pageLayouts[index];
  final first = index - index % 2;
  final left = layout.pageLayouts[first];
  return first + 1 < layout.pageLayouts.length
      ? left.expandToInclude(layout.pageLayouts[first + 1])
      : left;
}
