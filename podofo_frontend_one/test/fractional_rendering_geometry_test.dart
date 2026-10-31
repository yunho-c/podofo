import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/src/widgets/internals/partial_rendering.dart';

void main() {
  test('209 DPI preserves fractional page origin in a viewport-sized tile', () {
    const page = Rect.fromLTWH(98, 8, 612, 792);
    const scale = 209 / 72;
    const origin = Offset(-88.25, -549.5);
    final visible = Rect.fromLTWH(
      page.left - origin.dx / scale,
      page.top - origin.dy / scale,
      1600 / scale,
      1200 / scale,
    );
    final tile = pixelAlignedViewport(
      pageRect: page,
      visibleRect: visible,
      pageOriginPhysical: origin,
      scale: scale,
    )!;
    expect(tile.width, 1600);
    expect(tile.height, 1200);
    expect(tile.pageLeft, -88.25);
    expect(tile.pageTop, -549.5);
    expect(tile.paintRect.left, closeTo(visible.left, 1e-10));
    expect(tile.paintRect.width * scale, closeTo(1600, 1e-10));
  });

  test(
    'a partial page expands the tile but retains fractional edge placement',
    () {
      const page = Rect.fromLTWH(10, 20, 40, 30);
      const origin = Offset(100.25, 50.75);
      final tile = pixelAlignedViewport(
        pageRect: page,
        visibleRect: page,
        pageOriginPhysical: origin,
        scale: 2,
      )!;
      expect(tile.width, 81);
      expect(tile.height, 61);
      expect(tile.pageLeft, .25);
      expect(tile.pageTop, .75);
      expect(tile.paintRect, const Rect.fromLTWH(9.875, 19.625, 40.5, 30.5));
      expect(tile.paintRect.contains(page.topLeft), isTrue);
      expect(tile.paintRect.contains(page.bottomRight), isTrue);
    },
  );

  test(
    'integer parent movement reuses the grid, fractional movement changes it',
    () {
      const page = Rect.fromLTWH(10, 20, 40, 30);
      PixelAlignedViewport tile(double x) => pixelAlignedViewport(
        pageRect: page,
        visibleRect: page,
        pageOriginPhysical: Offset(x, 0),
        scale: 2,
      )!;
      expect(tile(0), tile(1));
      expect(tile(0).paintRect, isNot(tile(.25).paintRect));
      expect(tile(.25).pageLeft, .25);
    },
  );

  test(
    'rejects invalid geometry and tolerates floating-point boundary noise',
    () {
      const rect = Rect.fromLTWH(0, 0, 10, 10);
      for (final scale in [0.0, -1.0, double.nan, double.infinity, 1e308]) {
        expect(
          pixelAlignedViewport(
            pageRect: rect,
            visibleRect: rect,
            pageOriginPhysical: Offset.zero,
            scale: scale,
          ),
          isNull,
        );
      }
      final tile = pixelAlignedViewport(
        pageRect: rect,
        visibleRect: rect,
        pageOriginPhysical: const Offset(-1e-14, 1e-14),
        scale: 2,
      )!;
      expect(tile.width, 20);
      expect(tile.height, 20);
      expect(
        tile.pageLeft,
        -1e-14,
        reason: 'Only tile bounds snap, not the PDF transform',
      );
    },
  );
}
