import 'dart:ui' as ui;
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:podofo_one/src/widgets/components/pdf_link_hover_preview.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

void main() {
  setUpAll(() async {
    final font = FontLoader('packages/shadcn_flutter/GeistSans')
      ..addFont(
        rootBundle.load('packages/shadcn_flutter/lib/fonts/Geist-Regular.otf'),
      );
    await font.load();
  });
  testWidgets('preview fits small overlays and remains inert at each edge', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(const Color(0xffee2222), ui.BlendMode.src);
    final picture = recorder.endRecording();
    final image = await tester.runAsync(() => picture.toImage(720, 480));
    picture.dispose();
    var clicks = 0;
    for (final anchor in [const Offset(1, 1), const Offset(399, 299)]) {
      await tester.pumpWidget(
        shadcn.ShadcnApp(
          home: Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => clicks++,
                  child: const SizedBox.expand(),
                ),
              ),
              PdfLinkHoverPreview(
                anchor: anchor,
                label: 'Page 2',
                image: image,
              ),
            ],
          ),
        ),
      );
      final rect = tester.getRect(find.byType(shadcn.Card));
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.top, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(400));
      expect(rect.bottom, lessThanOrEqualTo(300));
      await tester.tapAt(rect.center);
      expect(tester.takeException(), isNull);
    }
    expect(clicks, 2);
    await tester.pumpWidget(const SizedBox.shrink());
    image!.dispose();
  });

  testWidgets('text fallback displays external or unsupported destinations', (
    tester,
  ) async {
    await tester.pumpWidget(
      const shadcn.ShadcnApp(
        home: Stack(
          children: [
            PdfLinkHoverPreview(
              anchor: Offset(10, 10),
              label: 'https://example.com/reference',
            ),
          ],
        ),
      ),
    );
    expect(find.text('https://example.com/reference'), findsOneWidget);
    expect(find.byType(RawImage), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'adaptive cards preserve the whole image at every edge, density and aspect ratio',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final images = <ui.Image>[];
      for (final size in [
        const Size(960, 240),
        const Size(180, 720),
        const Size(960, 720),
      ]) {
        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder);
        canvas.drawColor(const Color(0xffdceafe), ui.BlendMode.src);
        canvas.drawRect(
          Rect.fromLTWH(0, 0, size.width, 4),
          ui.Paint()..color = const Color(0xffee2222),
        );
        canvas.drawRect(
          Rect.fromLTWH(0, size.height - 4, size.width, 4),
          ui.Paint()..color = const Color(0xff2222ee),
        );
        final picture = recorder.endRecording();
        images.add(
          (await tester.runAsync(
            () => picture.toImage(size.width.toInt(), size.height.toInt()),
          ))!,
        );
        picture.dispose();
      }
      final boundary = GlobalKey();
      var clicks = 0, captures = 0;
      try {
        for (final viewport in [
          const Size(1000, 800),
          const Size(240, 180),
          const Size(80, 80),
        ]) {
          for (final ratio in [1.0, 1.5, 2.0, 3.0]) {
            tester.view.devicePixelRatio = ratio;
            tester.view.physicalSize = viewport * ratio;
            for (final image in images) {
              for (final anchor in [
                Offset.zero,
                Offset(viewport.width - 1, 0),
                Offset(0, viewport.height - 1),
                Offset(viewport.width - 1, viewport.height - 1),
              ]) {
                await tester.pumpWidget(
                  shadcn.ShadcnApp(
                    theme: shadcn.ThemeData(
                      colorScheme: ratio == 3
                          ? shadcn.ColorSchemes.darkZinc
                          : shadcn.ColorSchemes.lightZinc,
                    ),
                    home: RepaintBoundary(
                      key: boundary,
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () => clicks++,
                              child: const SizedBox.expand(),
                            ),
                          ),
                          PdfLinkHoverPreview(
                            anchor: anchor,
                            label: 'Reference [51] · Pages 4–5',
                            image: image,
                          ),
                        ],
                      ),
                    ),
                  ),
                );
                await tester.pump(const Duration(milliseconds: 300));
                final card = tester.getRect(find.byType(shadcn.Card));
                final raster = tester.getRect(
                  find.byKey(const ValueKey('pdf-link-preview-image')),
                );
                expect(card.width, lessThanOrEqualTo(480));
                expect(card.height, lessThanOrEqualTo(360));
                expect(card.left, greaterThanOrEqualTo(8));
                expect(card.top, greaterThanOrEqualTo(8));
                expect(card.right, lessThanOrEqualTo(viewport.width - 8));
                expect(card.bottom, lessThanOrEqualTo(viewport.height - 8));
                expect(
                  raster.width / raster.height,
                  closeTo(image.width / image.height, 1e-6),
                );
                expect(card.contains(raster.topLeft), true);
                expect(
                  card.contains(raster.bottomRight - const Offset(.001, .001)),
                  true,
                );
                expect(
                  tester.widget<RawImage>(find.byType(RawImage)).fit,
                  BoxFit.contain,
                );
                final before = clicks;
                await tester.tapAt(card.center);
                expect(clicks, before + 1);
                expect(tester.takeException(), isNull);
                if ((ratio == 2 || ratio == 3) &&
                    anchor == Offset.zero &&
                    viewport.width > 80) {
                  await tester.pump();
                  await tester.runAsync(() async {
                    final capture =
                        await (boundary.currentContext!.findRenderObject()
                                as RenderRepaintBoundary)
                            .toImage(pixelRatio: 2);
                    try {
                      await Directory('build/target-preview-m4/widgets')
                          .create(recursive: true);
                      await File(
                        'build/target-preview-m4/widgets/aspect-${captures++}.png',
                      ).writeAsBytes(
                        (await capture.toByteData(
                          format: ui.ImageByteFormat.png,
                        ))!.buffer.asUint8List(),
                      );
                    } finally {
                      capture.dispose();
                    }
                  });
                }
              }
            }
          }
        }
        expect(clicks, 144);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        for (final image in images) {
          image.dispose();
        }
      }
    },
  );
}
