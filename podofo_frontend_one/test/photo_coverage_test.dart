import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:podofo_one/src/dark_mode/photo_classifier.dart';
import 'package:podofo_one/src/dark_mode/photo_coverage.dart';
import 'package:podofo_one/src/dark_mode/photo_mask.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'classification ignores hidden colors and only compares visible neighbors',
    () {
      final rgb = File('test/fixtures/photo_dark_mode/photo.rgb')
          .readAsBytesSync();
      final valid = Uint8List(4096);
      for (var y = 0; y < 64; y++) {
        for (var x = 0; x < 64; x++) {
          if (x < 24 || x >= 40 || y < 24 || y >= 40) valid[y * 64 + x] = 1;
        }
      }
      final expected = classifyPhoto(rgb, opaque: valid);
      expect(expected.isLikelyPhoto, isTrue);
      final altered = Uint8List.fromList(rgb);
      for (var i = 0; i < valid.length; i++) {
        if (valid[i] == 0) altered.fillRange(i * 3, i * 3 + 3, 255);
      }
      final actual = classifyPhoto(altered, opaque: valid);
      expect(actual.entropy, expected.entropy);
      expect(actual.flatFraction, expected.flatFraction);
      expect(actual.edgeFraction, expected.edgeFraction);
      expect(actual.texturedTiles, expected.texturedTiles);
      // Photographic colors hidden behind the mask must not make a flat visible
      // panel photographic. Likewise, sparse visible noise is not enough evidence.
      for (var i = 0; i < valid.length; i++) {
        if (valid[i] != 0) altered.fillRange(i * 3, i * 3 + 3, 100);
      }
      expect(classifyPhoto(altered, opaque: valid).reason, 'low-tonal-entropy');
      valid.fillRange(0, valid.length, 0);
      valid.fillRange(0, 200, 1);
      expect(
        classifyPhoto(rgb, opaque: valid).reason,
        'insufficient-visible-samples',
      );
    },
  );

  test('texture min-pooling retains a single-cell hole through every page rotation', () async {
    final cells = Uint8List(256 * 256)..fillRange(0, 256 * 256, 1);
    cells[63 * 256 + 191] = 0;
    final coverage = PhotoCoverage.fromCells(256, 256, cells);
    const bounds = ui.Rect.fromLTWH(0, 0, 4096, 4096);
    // 32 mask texels square: one source hole is only 1/8 of a mask texel.
    const rect = ui.Rect.fromLTWH(512, 1024, 64, 64);
    for (var rotation = 0; rotation < 4; rotation++) {
      final region = PhotoMaskRegion(
        rect,
        coverage: coverage,
        quarterTurns: rotation,
      );
      final mask = await PhotoMask.create(bounds, [region]);
      try {
        final data = (await mask.image.toByteData())!.buffer.asUint8List();
        final sourceX = 191 ~/ 8, sourceY = 63 ~/ 8;
        final (hx, hy) = switch (rotation) {
          1 => (31 - sourceY, sourceX),
          2 => (31 - sourceX, 31 - sourceY),
          3 => (sourceY, 31 - sourceX),
          _ => (sourceX, sourceY),
        };
        for (var y = 0; y < 32; y++) {
          for (var x = 0; x < 32; x++) {
            expect(
              data[((512 + y) * 2048 + 256 + x) * 4 + 3],
              x == hx && y == hy ? 0 : 255,
              reason: 'rotation=$rotation texel=$x,$y hole=$hx,$hy',
            );
          }
        }
        expect(mask.regions, contains(region));
      } finally {
        mask.dispose();
      }
    }
  });

  test(
    'subtexel opaque islands cannot fill a texel or be reported as preserved',
    () async {
      final cells = Uint8List(256 * 256)..[100] = 1;
      final region = PhotoMaskRegion(
        const ui.Rect.fromLTWH(100, 100, 1, 1),
        coverage: PhotoCoverage.fromCells(256, 256, cells),
      );
      final mask = await PhotoMask.create(
        const ui.Rect.fromLTWH(0, 0, 2048, 2048),
        [region],
      );
      try {
        expect(mask.regions, isEmpty);
        final data = (await mask.image.toByteData())!.buffer.asUint8List();
        expect(data.any((v) => v != 0), isFalse);
      } finally {
        mask.dispose();
      }
    },
  );
}
