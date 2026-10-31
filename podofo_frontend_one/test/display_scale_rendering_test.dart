import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:podofo_one/src/rendering/fractional_page_renderer.dart';
import 'package:podofo_one/src/services/pdf_session.dart';

import 'fixtures/pdf_fixture.dart';

void main() {
  for (final fractional in [false, true]) {
    testWidgets(
      'settled low-zoom refinement debounces geometry, fractional=$fractional',
      (tester) async {
        tester.view.devicePixelRatio = 2;
        tester.view.physicalSize = const Size(1600, 1200);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final directory = Directory.systemTemp.createTempSync(
          'podofo-display-scale-',
        );
        final file = File('${directory.path}/fixture.pdf')
          ..writeAsBytesSync(pdfFixture(pageCount: 1));
        final session = (await tester.runAsync(() async {
          await pdfrxInitialize(tmpPath: directory.path);
          return PdfSession.open(file.path);
        }))!;
        final controller = PdfViewerController();
        var renders = 0;
        final initialGate = Completer<void>();
        Future<ui.Image?> renderer(
          PdfPage page,
          PdfViewportRenderRequest request,
        ) async {
          renders++;
          await initialGate.future;
          return fractional ? renderFractionalPage(page, request) : null;
        }

        PdfPageRenderingStatus? getStatus() =>
            controller.renderingStatus.value.firstOrNull;
        bool ready() => getStatus()?.mode == PdfPageRenderMode.fullResolution;
        try {
          await tester.pumpWidget(
            MaterialApp(
              home: PdfViewer(
                session.lease.reference,
                controller: controller,
                params: PdfViewerParams(
                  renderAtDisplayScale: true,
                  viewportRenderer: renderer,
                  behaviorControlParams: const PdfViewerBehaviorControlParams(
                    partialImageLoadingDelay: Duration(milliseconds: 150),
                  ),
                  sizeDelegateProvider: PdfViewerSizeDelegateProviderLegacy(
                    useAlternativeFitScaleAsMinScale: false,
                    minScale: .1,
                    calculateInitialZoom: (_, _, _, _) => .5,
                  ),
                ),
              ),
            ),
          );
          await _wait(
            tester,
            () => getStatus()?.mode == PdfPageRenderMode.refining,
          );
          expect(getStatus()!.targetScale * 72, closeTo(72, 1e-8));
          expect(getStatus()!.previewScale * 72, closeTo(200, 1e-8));
          // A preview remains available while the new display-scale tile is pending.
          initialGate.complete();
          await _wait(tester, ready);
          expect(getStatus()!.usesFractionalTransform, fractional);
          final firstCount = renders;

          // More than 150 ms of changing viewports must not issue intermediate
          // renders. Only the final requested geometry is worth rasterizing.
          for (final dpi in [96.0, 110.0, 120.0, 130.0, 144.0]) {
            controller.value = controller.calcMatrixFor(
              controller.layout.pageLayouts.single.center,
              zoom: dpi / 144,
            );
            await tester.pump();
            await _tick(tester, const Duration(milliseconds: 75));
            expect(renders, firstCount);
            expect(getStatus()!.mode, PdfPageRenderMode.refining);
          }
          // Repaints that do not change the viewport must neither starve nor
          // duplicate the scheduled (or in-flight) render.
          for (var i = 0; i < 12; i++) {
            controller.invalidate();
            await _tick(tester, const Duration(milliseconds: 20));
          }
          await _wait(tester, ready);
          expect(renders, firstCount + 1);
          expect(getStatus()!.targetScale * 72, closeTo(144, 1e-8));
          expect(getStatus()!.targetScale, lessThan(getStatus()!.previewScale));
          expect(getStatus()!.usesFractionalTransform, fractional);

          // Returning to an already cached viewport cancels a different pending
          // request; it must not publish later and replace the valid cached tile.
          final settled = controller.value.clone();
          controller.value = controller.calcMatrixFor(
            controller.layout.pageLayouts.single.center,
            zoom: 175 / 144,
          );
          await tester.pump();
          await _tick(tester, const Duration(milliseconds: 50));
          controller.value = settled;
          await tester.pump();
          for (var i = 0; i < 12; i++) {
            await _tick(tester, const Duration(milliseconds: 20));
          }
          expect(renders, firstCount + 1);
          expect(ready(), isTrue);
          expect(tester.takeException(), isNull);
        } finally {
          if (!initialGate.isCompleted) initialGate.complete();
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(() async {
            await session.close(discard: true);
            await PdfrxEntryFunctions.instance.stopBackgroundWorker();
          });
          directory.deleteSync(recursive: true);
        }
      },
      skip: !Platform.isMacOS,
    );
  }
}

Future<void> _tick(WidgetTester tester, Duration elapsed) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 10)),
  );
  await tester.pump(elapsed);
  await tester.pump();
}

Future<void> _wait(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 300; i++) {
    await _tick(tester, const Duration(milliseconds: 20));
    if (ready()) return;
  }
  fail('Timed out waiting for display-scale refinement');
}
