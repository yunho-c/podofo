import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:podofo_one/src/rendering/fractional_page_renderer.dart';
import 'package:podofo_one/src/services/pdf_session.dart';

import 'fixtures/form_pdf.dart';
import 'fixtures/pdf_fixture.dart';

void main() {
  testWidgets('fractional tile reuse, parent phase, and late image disposal', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(1600, 1200);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final temporary = Directory.systemTemp.createTempSync('podofo-fractional-');
    final file = File('${temporary.path}/page.pdf')
      ..writeAsBytesSync(pdfFixture(pageCount: 1));
    final session = (await tester.runAsync(() async {
      await pdfrxInitialize(tmpPath: temporary.path);
      return PdfSession.open(file.path);
    }))!;
    final controller = PdfViewerController();
    final offset = ValueNotifier(Offset.zero);
    final requests = <PdfViewportRenderRequest>[];
    Completer<void>? gate;
    ui.Image? delayedImage;
    Future<ui.Image?> renderer(
      PdfPage page,
      PdfViewportRenderRequest request,
    ) async {
      requests.add(request);
      final image = await renderFractionalPage(page, request);
      if (gate != null && image != null) {
        delayedImage = image;
        await gate.future;
      }
      return image;
    }

    bool ready() => controller.renderingStatus.value.any(
      (s) =>
          s.mode == PdfPageRenderMode.fullResolution &&
          s.usesFractionalTransform,
    );
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: ValueListenableBuilder<Offset>(
            valueListenable: offset,
            builder: (_, value, child) =>
                Transform.translate(offset: value, child: child),
            child: PdfViewer(
              session.lease.reference,
              controller: controller,
              params: PdfViewerParams(
                viewportRenderer: renderer,
                getPageRenderingScale: (_, _, _, _) => .5,
                sizeDelegateProvider: const PdfViewerSizeDelegateProviderLegacy(
                  maxScale: 8,
                  minScale: .1,
                ),
              ),
            ),
          ),
        ),
      );
      await _wait(tester, () => controller.isReady);
      controller.value = controller.calcMatrixFor(
        controller.layout.pageLayouts.single.center,
        zoom: 209 / 72 / 2,
      );
      await _wait(tester, ready);
      final count = requests.length;
      controller.invalidate();
      for (var i = 0; i < 5; i++) {
        await _tick(tester);
      }
      expect(requests.length, count, reason: 'A settled tile is reused');

      offset.value = const Offset(.125, .25); // .25 and .5 physical pixels.
      await tester.pump();
      controller.invalidate();
      await _wait(tester, () => requests.length > count && ready());
      expect(
        requests.last.pageLeft,
        isNot(requests[count - 1].pageLeft),
        reason: 'Parent movement must invalidate the fractional grid',
      );

      // Hold an already decoded image across unmount. Even a renderer returning
      // late after cancellation must not leak or publish into the next viewer.
      gate = Completer<void>();
      final matrix = controller.value.clone();
      matrix.storage[13] += .25;
      controller.value = matrix;
      await _wait(tester, () => delayedImage != null);
      expect(delayedImage!.debugDisposed, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(requests.last.cancellationToken.isCanceled, isTrue);
      gate.complete();
      await _wait(tester, () => delayedImage!.debugDisposed);
      expect(controller.renderingStatus.value, isEmpty);
      expect(tester.takeException(), isNull);
    } finally {
      if (gate != null && !gate.isCompleted) gate.complete();
      await tester.pumpWidget(const SizedBox.shrink());
      offset.dispose();
      await tester.runAsync(() async {
        await session.close(discard: true);
        await PdfrxEntryFunctions.instance.stopBackgroundWorker();
      });
      temporary.deleteSync(recursive: true);
    }
  }, skip: !Platform.isMacOS);

  testWidgets(
    'forms fall back and cancelled native work survives document close',
    (tester) async {
      final temporary = Directory.systemTemp.createTempSync(
        'podofo-fractional-fallback-',
      );
      final form = File('${temporary.path}/form.pdf')
        ..writeAsBytesSync(formPdf());
      final plain = File('${temporary.path}/plain.pdf')
        ..writeAsBytesSync(pdfFixture(pageCount: 1));
      await tester.runAsync(() async {
        await pdfrxInitialize(tmpPath: temporary.path);
        final session = await PdfSession.open(form.path);
        try {
          final page = session.lease.document.pages.single;
          final image = await renderFractionalPage(
            page,
            _request(page.createCancellationToken()),
          );
          expect(
            image,
            isNull,
            reason: 'AcroForm must use the ordinary renderer',
          );
        } finally {
          await session.close(discard: true);
        }
        final ordinary = await PdfSession.open(plain.path);
        final page = ordinary.lease.document.pages.single;
        final token = page.createCancellationToken();
        final pending = renderFractionalPage(page, _request(token));
        token.cancel();
        await ordinary.close(discard: true);
        expect(
          await pending,
          isNull,
          reason: 'Cancelled work must never return an image',
        );
        await PdfrxEntryFunctions.instance.stopBackgroundWorker();
      });
      expect(tester.takeException(), isNull);
      temporary.deleteSync(recursive: true);
    },
    skip: !Platform.isMacOS,
  );
}

PdfViewportRenderRequest _request(PdfPageRenderCancellationToken token) =>
    PdfViewportRenderRequest(
      width: 800,
      height: 600,
      scaleX: 209 / 72,
      scaleY: 209 / 72,
      pageLeft: -.25,
      pageTop: -.5,
      flags: PdfPageRenderFlags.limitedImageCache,
      annotationRenderingMode: PdfAnnotationRenderingMode.annotationAndForms,
      cancellationToken: token,
    );

Future<void> _tick(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 10)),
  );
  await tester.pump(const Duration(milliseconds: 20));
  await tester.pump();
}

Future<void> _wait(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 300; i++) {
    await _tick(tester);
    if (ready()) return;
  }
  fail('Timed out waiting for fractional rendering');
}
