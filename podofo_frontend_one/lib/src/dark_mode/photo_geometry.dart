import 'dart:ui';

import 'package:pdfrx/pdfrx.dart';

import 'photo_analysis.dart';

/// Layouts supported by PoDoFo are vertical rows of one or two pages. Binary
/// search the rows, then inspect only intersecting pages, even in a long paper.
List<int> visiblePhotoPages(
  List<Rect> layout,
  Rect visible, {
  required bool twoPages,
}) {
  final stride = twoPages ? 2 : 1;
  final rows = (layout.length + stride - 1) ~/ stride;
  Rect row(int index) {
    final first = index * stride;
    return stride == 2 && first + 1 < layout.length
        ? layout[first].expandToInclude(layout[first + 1])
        : layout[first];
  }

  var lo = 0;
  var hi = rows;
  while (lo < hi) {
    final mid = (lo + hi) ~/ 2;
    if (row(mid).bottom <= visible.top) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  final result = <int>[];
  for (var i = lo; i < rows && row(i).top < visible.bottom; i++) {
    for (var j = i * stride; j < (i + 1) * stride && j < layout.length; j++) {
      if (layout[j].overlaps(visible)) result.add(j + 1);
    }
  }
  return result;
}

/// Normalize to the ImageFiltered input, not the window or physical screen.
/// Using pdfrx's rotation conversion avoids independently rotating twice.
Rect photoViewportRect(
  PhotoRegion region,
  PdfPage page,
  Rect layout,
  Rect visible,
) {
  if (region.right <= region.left || region.top <= region.bottom) {
    return Rect.zero;
  }
  final documentRect = PdfRect(
    region.left,
    region.top,
    region.right,
    region.bottom,
  ).toRectInDocument(page: page, pageRect: layout).intersect(layout);
  return Rect.fromLTRB(
    (documentRect.left - visible.left) / visible.width,
    (documentRect.top - visible.top) / visible.height,
    (documentRect.right - visible.left) / visible.width,
    (documentRect.bottom - visible.top) / visible.height,
  ).intersect(const Rect.fromLTRB(0, 0, 1, 1));
}
