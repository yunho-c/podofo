import 'dart:ui';

import 'package:pdfrx/pdfrx.dart';

/// Coverage of visible source pixels, not whitespace inside annotation rectangles.
/// All bounds use displayed page points. Count at native page-point resolution.
Future<Map<String, Object>> previewPixelMetrics(
  PdfPage page,
  List<Rect> selected,
  List<Rect> required,
  List<Rect> excluded,
) async {
  final raster = (await page.render())!;
  try {
    Map<String, int> measure(Rect box) {
      var ink = 0, covered = 0;
      final sx = raster.width / page.width, sy = raster.height / page.height;
      for (
        var y = (box.top * sy).floor().clamp(0, raster.height);
        y < (box.bottom * sy).ceil().clamp(0, raster.height);
        y++
      ) {
        for (
          var x = (box.left * sx).floor().clamp(0, raster.width);
          x < (box.right * sx).ceil().clamp(0, raster.width);
          x++
        ) {
          final p = (y * raster.width + x) * 4;
          if (raster.pixels[p] > 245 &&
              raster.pixels[p + 1] > 245 &&
              raster.pixels[p + 2] > 245) {
            continue;
          }
          ink++;
          if (selected.any(
            (r) => r.contains(Offset((x + .5) / sx, (y + .5) / sy)),
          )) {
            covered++;
          }
        }
      }
      return {'ink': ink, 'covered': covered};
    }

    return {
      'required': required.map(measure).toList(),
      'excluded': excluded.map(measure).toList(),
    };
  } finally {
    raster.dispose();
  }
}

Rect previewFixtureRect(dynamic value) {
  final b = (value as List).cast<num>();
  return Rect.fromLTRB(
    b[0].toDouble(),
    b[1].toDouble(),
    b[2].toDouble(),
    b[3].toDouble(),
  );
}
