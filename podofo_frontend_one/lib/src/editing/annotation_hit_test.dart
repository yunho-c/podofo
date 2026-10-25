import 'annotation_edit.dart';

/// Hit individual PDF quads, not the bounds spanning lines or column gaps.
/// Coordinates are unrotated and relative to the page bounding box.
AnnotationRecord? textMarkupAt(
  Iterable<AnnotationRecord> records,
  int pageNumber,
  double x,
  double y,
) {
  AnnotationRecord? hit;
  for (final record in records) {
    if (record.pageNumber != pageNumber || record.flags & (2 | 32) != 0) {
      continue;
    }
    if (record.quads.any((quad) => _contains(quad, x, y)) &&
        (hit == null || record.index > hit.index)) {
      hit = record;
    }
  }
  return hit;
}

bool _contains(List<double> q, double x, double y) {
  if (q.length != 8 || !q.every((v) => v.isFinite)) return false;
  // PDFium text-markup quads use top-left, top-right, bottom-left, bottom-right.
  const perimeter = [0, 2, 6, 4];
  var positive = false, negative = false;
  var area = 0.0;
  for (var i = 0; i < 4; i++) {
    final a = perimeter[i], b = perimeter[(i + 1) % 4];
    final cross =
        (q[b] - q[a]) * (y - q[a + 1]) - (q[b + 1] - q[a + 1]) * (x - q[a]);
    positive |= cross > 1e-8;
    negative |= cross < -1e-8;
    area += q[a] * q[b + 1] - q[b] * q[a + 1];
  }
  return area.abs() > 1e-8 && !(positive && negative);
}
