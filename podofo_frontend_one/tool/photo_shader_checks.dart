import 'dart:io';
import 'dart:ui' as ui;

import 'package:pdfrx/pdfrx.dart';
import 'package:podofo_one/src/dark_mode/photo_analysis.dart';
import 'package:podofo_one/src/dark_mode/photo_geometry.dart';
import 'package:podofo_one/src/dark_mode/photo_mask.dart';

/// Used by the Release probe and the explicitly Impeller-enabled test runner.
/// Offscreen GPU readback, not a substitute for inspecting the native window.
Future<Map<String, Object>> checkPhotoShader(
  String fixture,
  Directory output, {
  List<int> pageNumbers = const [1, 2, 3, 4, 5, 11],
  int? expectedPhotos = 1,
}) async {
  if (!ui.ImageFilter.isShaderFilterSupported) {
    throw StateError('Requires the actual Impeller ImageFilter.shader backend');
  }
  output.createSync(recursive: true);
  final pdf = await PdfDocument.openFile(fixture);
  final originalProgram = await ui.FragmentProgram.fromAsset(
    'shaders/invert.frag',
  );
  final photoProgram = await ui.FragmentProgram.fromAsset(
    'shaders/invert_photos.frag',
  );
  var compared = 0;
  final analyses = <Map<String, Object?>>[];
  final timings = <String, List<int>>{'original': [], 'selective': []};
  try {
    // All rotations, crop, and an existing annotation on top of the photograph.
    for (final number in pageNumbers) {
      final page = pdf.pages[number - 1];
      final analysis = await analyzePhotos(pdf, number);
      analyses.add({
        'page': number,
        'fallback': analysis.fallback,
        'elapsed_us': analysis.elapsedMicroseconds,
        'photos': analysis.regions.length,
        'candidates': [
          for (final c in analysis.candidates)
            {
              'path': c.objectId,
              'reason': c.reason,
              'opaque_fraction': c.coverage?.fraction,
              'rect': [
                c.region.left,
                c.region.bottom,
                c.region.right,
                c.region.top,
              ],
            },
        ],
      });
      if (analysis.regions.isEmpty ||
          (expectedPhotos != null &&
              analysis.regions.length != expectedPhotos)) {
        throw StateError('Unexpected photos on page $number: ${analyses.last}');
      }
      final regions = [
        for (final candidate in analysis.candidates)
          if (candidate.reason == 'likely-photo')
            PhotoMaskRegion(
              photoViewportRect(
                candidate.region,
                page,
                ui.Rect.fromLTWH(0, 0, page.width, page.height),
                ui.Rect.fromLTWH(0, 0, page.width, page.height),
              ),
              coverage: candidate.coverage,
              quarterTurns: candidate.coverage == null
                  ? 0
                  : page.rotation.index,
            ),
      ];
      for (final scale in [1.0, 2.0]) {
        final width = (page.width * scale).round();
        final height = (page.height * scale).round();
        final raster = (await page.render(
          fullWidth: width.toDouble(),
          fullHeight: height.toDouble(),
        ))!;
        final source = await raster.createImage();
        raster.dispose();
        final sourceBytes = (await source.toByteData())!.buffer.asUint8List();
        final pageBounds = ui.Rect.fromLTWH(0, 0, page.width, page.height);
        final mask = await PhotoMask.create(pageBounds, [
          for (final candidate in analysis.candidates)
            if (candidate.reason == 'likely-photo')
              photoMaskRegion(candidate, page, pageBounds),
        ]);
        try {
          for (final strength in [0.0, .6, 1.0]) {
            final original = originalProgram.fragmentShader()
              ..setFloat(2, strength);
            final selective = photoProgram.fragmentShader();
            mask.configure(selective, strength, pageBounds);
            Future<ui.Image> filter(
              ui.FragmentShader shader,
              String label,
            ) async {
              final watch = Stopwatch()..start();
              final recorder = ui.PictureRecorder();
              final canvas = ui.Canvas(recorder);
              canvas.saveLayer(
                ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
                ui.Paint()..imageFilter = ui.ImageFilter.shader(shader),
              );
              canvas.drawImage(source, ui.Offset.zero, ui.Paint());
              canvas.restore();
              final picture = recorder.endRecording();
              final image = await picture.toImage(width, height);
              picture.dispose();
              timings[label]!.add(watch.elapsedMicroseconds);
              return image;
            }

            final normal = await filter(original, 'original');
            final preserved = await filter(selective, 'selective');
            try {
              final base = (await normal.toByteData())!.buffer.asUint8List();
              final actual = (await preserved.toByteData())!.buffer
                  .asUint8List();
              for (var y = 2; y < height - 2; y += 3) {
                for (var x = 2; x < width - 2; x += 3) {
                  final point = ui.Offset((x + .5) / width, (y + .5) / height);
                  // Avoid subpixel edge sampling differences in GPU backends.
                  final inside = regions.any(
                    (r) => _covers(r, point, 2 / width, 2 / height),
                  );
                  // Internal mask boundaries get the same exclusion as outer
                  // rectangle edges. The interiors of holes are still checked
                  // against whole-page inversion, including fractional alpha.
                  final edge =
                      !inside &&
                      regions.any(
                        (r) => _nearCoverage(r, point, 2 / width, 2 / height),
                      );
                  if (edge && !inside) continue;
                  final expected = inside ? sourceBytes : base;
                  final offset = (y * width + x) * 4;
                  for (var c = 0; c < 4; c++) {
                    if ((expected[offset + c] - actual[offset + c]).abs() > 3) {
                      throw StateError(
                        'Shader mismatch page=$number scale=$scale strength=$strength xy=$x,$y channel=$c',
                      );
                    }
                  }
                  compared++;
                }
              }
              if (scale == 1 && strength == 1) {
                for (final pair in [
                  ('natural', source),
                  ('original', normal),
                  ('selective', preserved),
                ]) {
                  final png = (await pair.$2.toByteData(
                    format: ui.ImageByteFormat.png,
                  ))!;
                  await File('${output.path}/page-$number-${pair.$1}.png')
                      .writeAsBytes(png.buffer.asUint8List());
                }
              }
            } finally {
              normal.dispose();
              preserved.dispose();
              original.dispose();
              selective.dispose();
            }
          }
        } finally {
          mask.dispose();
          source.dispose();
        }
      }
    }
    return {
      'impeller_shader_supported': true,
      'compared_pixel_samples': compared,
      'page_numbers': pageNumbers,
      'analyses': analyses,
      'scales': [1, 2],
      'strengths': [0, .6, 1],
      'offscreen_to_image_us': timings,
      'timing_limit': 'Includes recording/readback; not interactive frame timings or GPU-only cost.',
    };
  } finally {
    await pdf.dispose();
  }
}

bool _covers(PhotoMaskRegion region, ui.Offset p, double dx, double dy) {
  final rect = region.rect;
  if (!rect.contains(p - ui.Offset(dx, dy)) ||
      !rect.contains(p + ui.Offset(dx, dy))) {
    return false;
  }
  return region.covers(
    (p.dx - dx - rect.left) / rect.width,
    (p.dy - dy - rect.top) / rect.height,
    (p.dx + dx - rect.left) / rect.width,
    (p.dy + dy - rect.top) / rect.height,
  );
}

bool _nearCoverage(PhotoMaskRegion region, ui.Offset p, double dx, double dy) {
  if (!region.rect.inflate(dx > dy ? dx : dy).contains(p)) return false;
  if (region.coverage == null) return true;
  for (final y in [-dy, 0.0, dy]) {
    for (final x in [-dx, 0.0, dx]) {
      if (_covers(region, p + ui.Offset(x, y), 1e-9, 1e-9)) return true;
    }
  }
  return false;
}
