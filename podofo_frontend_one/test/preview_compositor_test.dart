import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:podofo_one/src/previews/link_target.dart';
import 'package:podofo_one/src/previews/preview_compositor.dart';
import 'package:podofo_one/src/workers/link_preview_worker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'four ordered crops fit the density and viewport budgets without clipping',
    () {
      final document = _Document();
      final target = _target([
        (page: 1, bounds: const ui.Rect.fromLTRB(20.1, 30.7, 290.2, 92.4)),
        (page: 1, bounds: const ui.Rect.fromLTRB(310.5, 40.2, 590.9, 103.6)),
        (page: 2, bounds: const ui.Rect.fromLTRB(30.3, 55.8, 570.1, 113.9)),
        (page: 2, bounds: const ui.Rect.fromLTRB(30.8, 141.2, 568.9, 171.7)),
      ]);
      for (final ratio in [0.5, 1.0, 1.5, 2.0, 4.0, double.nan]) {
        for (final maxSize in [
          semanticPreviewMaxSize,
          const ui.Size(163, 211),
        ]) {
          final plan = PreviewComposition.plan(
            document,
            target,
            ratio,
            maxSize: maxSize,
          )!;
          final density = ratio.isFinite ? ratio.clamp(1, 2) : 1;
          expect(plan.width, lessThanOrEqualTo(maxSize.width * density));
          expect(plan.height, lessThanOrEqualTo(maxSize.height * density));
          expect(plan.bytes, lessThanOrEqualTo(PreviewComposition.maxBytes));
          expect(plan.crops.map((c) => c.page), [1, 1, 2, 2]);
          for (var i = 0; i < plan.crops.length; i++) {
            final crop = plan.crops[i], bounds = target.parts[i].bounds;
            final scale = crop.fullWidth / document.pages[crop.page - 1].width;
            expect(
              crop.fullHeight / document.pages[crop.page - 1].height,
              closeTo(scale, 1e-9),
            );
            // Outward rounding includes every fractional boundary, never cuts ink.
            expect(crop.x, lessThanOrEqualTo(bounds.left * scale));
            expect(crop.y, lessThanOrEqualTo(bounds.top * scale));
            expect(
              crop.x + crop.width,
              greaterThanOrEqualTo(bounds.right * scale),
            );
            expect(
              crop.y + crop.height,
              greaterThanOrEqualTo(bounds.bottom * scale),
            );
            expect(crop.outputX, greaterThanOrEqualTo(0));
            expect(crop.outputX + crop.width, lessThanOrEqualTo(plan.width));
            expect(crop.outputY + crop.height, lessThanOrEqualTo(plan.height));
            if (i > 0) {
              final previous = plan.crops[i - 1];
              expect(
                crop.outputY,
                greaterThan(previous.outputY + previous.height),
              );
            }
          }
        }
      }
    },
  );

  test(
    'invalid, oversized and nonadjacent selections allocate no native rasters',
    () async {
      final document = _Document();
      const one = (page: 1, bounds: ui.Rect.fromLTWH(10, 10, 100, 60));
      final invalid = [
        <({int page, ui.Rect bounds})>[],
        List.filled(5, one),
        [one, (page: 3, bounds: one.bounds)],
        [(page: 2, bounds: one.bounds), one],
        [(page: 0, bounds: one.bounds)],
        [(page: 4, bounds: one.bounds)],
        [(page: 1, bounds: const ui.Rect.fromLTRB(-1, 0, 100, 100))],
        [(page: 1, bounds: const ui.Rect.fromLTRB(590, 780, 620, 800))],
        [(page: 1, bounds: ui.Rect.zero)],
        [(page: 1, bounds: const ui.Rect.fromLTRB(0, 0, double.nan, 10))],
        [(page: 1, bounds: const ui.Rect.fromLTRB(0, 0, 10, double.infinity))],
        // Tiny targets may not demand unbounded virtual page dimensions.
        [(page: 1, bounds: const ui.Rect.fromLTWH(10, 10, .001, .001))],
      ];
      final accounting = PreviewRasterAccounting();
      for (final parts in invalid) {
        expect(
          await renderPreviewComposition(
            document,
            _target(parts),
            2,
            PreviewCancellation(),
            accounting: accounting,
          ),
          isNull,
        );
      }
      for (final size in [
        ui.Size.zero,
        const ui.Size(-1, 100),
        const ui.Size(double.infinity, 100),
        const ui.Size(100, double.nan),
        const ui.Size(1, 1),
      ]) {
        expect(
          PreviewComposition.plan(document, _target([one]), 2, maxSize: size),
          isNull,
        );
      }
      expect(document.calls, 0);
      expect(accounting.liveBytes, 0);
      expect(accounting.peakBytes, 0);
    },
  );

  test('success releases each crop before the next and detaches cancellation listeners', () async {
    final document = _Document();
    final cancellation = PreviewCancellation();
    final accounting = PreviewRasterAccounting();
    final target = _threeParts();
    final plan = PreviewComposition.plan(document, target, 2)!;
    final image = (await renderPreviewComposition(
      document,
      target,
      2,
      cancellation,
      accounting: accounting,
    ))!;
    try {
      expect(image.width, plan.width);
      expect(image.height, plan.height);
      expect(document.calls, 3);
      expect(document.peakRasters, 1);
      expect(document.liveRasters, 0);
      expect(document.disposals, 3);
      expect(accounting.crops, 3);
      expect(accounting.liveBytes, 0);
      expect(
        accounting.peakBytes,
        plan.bytes +
            plan.crops.map((c) => c.bytes).reduce((a, b) => a > b ? a : b),
      );
      expect(
        accounting.peakBytes,
        lessThanOrEqualTo(2 * PreviewComposition.maxBytes),
      );
      // All tokens are completed and detached; a later cancel cannot reuse them.
      cancellation.cancel();
      expect(document.tokens.every((t) => !t.isCanceled), true);
      final pixels = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      for (var i = 0; i < plan.crops.length; i++) {
        final crop = plan.crops[i];
        final offset = (crop.outputY * image.width + crop.outputX) * 4;
        expect(pixels.getUint8(offset), i + 1); // BGRA red -> RGBA red
        expect(pixels.getUint8(offset + 3), 255);
        if (i > 0) {
          expect(
            pixels.getUint32((crop.outputY - 1) * image.width * 4),
            0xffffffff,
          );
        }
      }
    } finally {
      image.dispose();
    }
  });

  for (final failure in ['null', 'throw', 'cancel', 'size', 'pixels']) {
    test(
      'second crop $failure discards the composite and drains resources',
      () async {
        final document = _Document();
        final cancellation = PreviewCancellation();
        final accounting = PreviewRasterAccounting();
        document.onRender = (call, token) {
          if (call != 2) return null;
          if (failure == 'cancel') {
            cancellation.cancel();
            expect(token.isCanceled, true);
          }
          return failure;
        };
        final future = renderPreviewComposition(
          document,
          _threeParts(),
          2,
          cancellation,
          accounting: accounting,
        );
        if (failure == 'throw') {
          await expectLater(future, throwsStateError);
        } else {
          expect(await future, isNull);
        }
        expect(document.calls, 2);
        expect(document.peakRasters, 1);
        expect(document.liveRasters, 0);
        expect(
          document.disposals,
          failure == 'null' || failure == 'throw' ? 1 : 2,
        );
        expect(accounting.liveBytes, 0);
        expect(
          accounting.peakBytes,
          lessThanOrEqualTo(2 * PreviewComposition.maxBytes),
        );
        cancellation.cancel();
        expect(document.tokens.first.isCanceled, false);
        if (failure != 'cancel') expect(document.tokens.last.isCanceled, false);
      },
    );
  }

  test(
    'cancel before rendering does not allocate a composite or crop',
    () async {
      final document = _Document(), accounting = PreviewRasterAccounting();
      expect(
        await renderPreviewComposition(
          document,
          _threeParts(),
          2,
          PreviewCancellation()..cancel(),
          accounting: accounting,
        ),
        isNull,
      );
      expect(document.calls, 0);
      expect(accounting.peakBytes, 0);
    },
  );

  test(
    'large semantic images retain the six MiB decoded cache bound',
    () async {
      final cache = LinkPreviewCache();
      final document = _Document();
      final target = _target([
        (page: 1, bounds: const ui.Rect.fromLTWH(0, 0, 400, 300)),
      ]);
      try {
        final images = <ui.Image>[];
        for (var i = 0; i < 4; i++) {
          final image = (await renderPreviewComposition(
            document,
            target,
            2,
            PreviewCancellation(),
          ))!;
          images.add(image);
          cache.put(i, image);
          expect(cache.bytes, lessThanOrEqualTo(6 * 1024 * 1024));
        }
        expect(cache.length, 2);
        expect(images.take(2).every((image) => image.debugDisposed), true);
        final clone = cache.get(3)!;
        cache.clear();
        expect(images.every((image) => image.debugDisposed), true);
        expect(clone.debugDisposed, false);
        clone.dispose();
        expect(cache.bytes, 0);
      } finally {
        cache.clear();
      }
    },
  );
}

ResolvedLinkTarget _target(List<({int page, ui.Rect bounds})> parts) =>
    ResolvedLinkTarget(
      tier: LinkTargetTier.matchedIdentity,
      kind: LinkTargetKind.figure,
      reason: 'Compositor test selection',
      parts: parts,
    );

ResolvedLinkTarget _threeParts() => _target([
  (page: 1, bounds: const ui.Rect.fromLTWH(30, 30, 250, 80)),
  (page: 1, bounds: const ui.Rect.fromLTWH(320, 30, 250, 80)),
  (page: 2, bounds: const ui.Rect.fromLTWH(30, 30, 540, 50)),
]);

class _Document implements PdfDocument {
  @override
  late final pages = [for (var i = 1; i <= 3; i++) _Page(this, i)];
  final tokens = <_Token>[];
  int calls = 0, liveRasters = 0, peakRasters = 0, disposals = 0;
  String? Function(int, _Token)? onRender;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Page implements PdfPage {
  _Page(this.document, this.pageNumber);
  @override
  final _Document document;
  @override
  final int pageNumber;
  @override
  double get width => 612;
  @override
  double get height => 792;
  @override
  PdfPageRenderCancellationToken createCancellationToken() {
    final token = _Token();
    document.tokens.add(token);
    return token;
  }

  @override
  Future<PdfImage?> render({
    int x = 0,
    int y = 0,
    int? width,
    int? height,
    double? fullWidth,
    double? fullHeight,
    int? backgroundColor,
    PdfPageRotation? rotationOverride,
    PdfAnnotationRenderingMode annotationRenderingMode =
        PdfAnnotationRenderingMode.annotationAndForms,
    int flags = PdfPageRenderFlags.none,
    PdfPageRenderCancellationToken? cancellationToken,
  }) async {
    expect(
      document.liveRasters,
      0,
      reason: 'Release the previous crop before requesting another',
    );
    final call = ++document.calls;
    final failure = document.onRender?.call(call, cancellationToken as _Token);
    if (failure == 'null') return null;
    if (failure == 'throw') throw StateError('Synthetic render failure');
    return _Raster(
      document,
      failure == 'size' ? width! + 1 : width!,
      height!,
      invalidPixels: failure == 'pixels',
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Token implements PdfPageRenderCancellationToken {
  @override
  bool isCanceled = false;
  @override
  void cancel() => isCanceled = true;
}

class _Raster implements PdfImage {
  _Raster(this.owner, this.width, this.height, {bool invalidPixels = false})
    : pixels = Uint8List(invalidPixels ? 1 : width * height * 4) {
    owner.liveRasters++;
    if (owner.liveRasters > owner.peakRasters) {
      owner.peakRasters = owner.liveRasters;
    }
    if (!invalidPixels) {
      for (var i = 0; i < pixels.length; i += 4) {
        pixels[i + 2] = owner.calls;
        pixels[i + 3] = 255;
      }
    }
  }
  final _Document owner;
  @override
  final int width, height;
  @override
  final Uint8List pixels;
  bool disposed = false;
  @override
  void dispose() {
    expect(disposed, false);
    disposed = true;
    owner.liveRasters--;
    owner.disposals++;
  }
}
