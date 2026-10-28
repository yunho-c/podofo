import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:podofo_one/src/widgets/components/pdf_link_hover_preview.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

void main() {
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
}
