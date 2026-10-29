import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:podofo_one/src/dark_mode/photo_filter.dart';
import 'package:podofo_one/src/dark_mode/photo_analysis.dart';
import 'package:podofo_one/src/dark_mode/photo_geometry.dart';
import 'package:podofo_one/src/services/pdf_session.dart';
import 'package:podofo_one/src/widgets/components/pdf_page_layout.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'mode switches preserve viewer, navigation, overlays and spread geometry',
    (tester) async {
      late PdfSession session;
      ui.FragmentShader? original;
      ui.FragmentProgram? selective;
      await tester.runAsync(() async {
        await pdfrxInitialize();
        session = await PdfSession.open(
          'test/fixtures/photo_dark_mode/mixed.pdf',
        );
        if (ui.ImageFilter.isShaderFilterSupported) {
          original = (await ui.FragmentProgram.fromAsset(
            'shaders/invert.frag',
          )).fragmentShader()..setFloat(2, 1);
          selective = await ui.FragmentProgram.fromAsset(
            'shaders/invert_photos.frag',
          );
        }
      });
      final controller = PdfViewerController();
      var preserve = false;
      var invert = true;
      var twoPages = false;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return Padding(
                padding: const EdgeInsets.fromLTRB(33, 17, 41, 29),
                child: RepaintBoundary(
                  key: const ValueKey('photo-capture'),
                  child: PhotoPreservingFilter(
                    session: session,
                    revision: session.revision,
                    controller: controller,
                    enabled: invert,
                    selective: preserve,
                    twoPages: twoPages,
                    strength: 1,
                    defaultShader: original,
                    program: selective,
                    child: PdfViewer(
                      session.lease.reference,
                      controller: controller,
                      params: PdfViewerParams(
                        layoutPages: twoPages ? layoutTwoPages : null,
                        pagePaintCallbacks: [
                          (canvas, rect, page) {
                            // Selection/search-like translucent overlay remains on top.
                            canvas.drawRect(
                              Rect.fromLTWH(
                                rect.left + 25,
                                rect.top + 50,
                                40,
                                20,
                              ),
                              Paint()..color = const Color(0x8800ff00),
                            );
                          },
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      );
      await _wait(tester, () => controller.isReady);
      final state = tester.state(find.byType(PdfViewer));
      unawaited(controller.goToPage(pageNumber: 3, duration: Duration.zero));
      await _wait(tester, () => controller.pageNumber == 3);
      final text = await tester.runAsync(
        () => session.lease.document.pages[2].loadStructuredText(),
      );
      final word = text!.fragments.first.bounds.toRectInDocument(
        page: session.lease.document.pages[2],
        pageRect: controller.layout.pageLayouts[2],
      );
      await _withPumps(
        tester,
        () => controller.textSelectionDelegate.selectWord(word.center),
      );
      final selectedText = await _withPumps(
        tester,
        controller.textSelectionDelegate.getSelectedText,
      );
      expect(selectedText, isNotEmpty);
      final matrix = controller.value.clone();
      update(() => preserve = true);
      await _settle(tester);
      expect(tester.state(find.byType(PdfViewer)), same(state));
      expect(controller.value, matrix);
      expect(controller.pageNumber, 3);
      expect(
        await _withPumps(
          tester,
          controller.textSelectionDelegate.getSelectedText,
        ),
        selectedText,
      );
      update(() => twoPages = true);
      await _settle(tester);
      unawaited(
        controller.goTo(
          controller.calcMatrixForRect(
            controller.layout.pageLayouts[0].expandToInclude(
              controller.layout.pageLayouts[1],
            ),
          ),
          duration: Duration.zero,
        ),
      );
      await _settle(tester);
      expect(
        controller.layout.pageLayouts[0].center.dy,
        controller.layout.pageLayouts[1].center.dy,
      );
      final spreadMatrix = controller.value.clone();
      update(() => preserve = false);
      await _settle(tester);
      expect(controller.value, spreadMatrix);
      expect(tester.state(find.byType(PdfViewer)), same(state));
      if (selective != null) {
        final captures = <String, Uint8List>{};
        var width = 0;
        var height = 0;
        for (final mode in ['natural', 'original', 'selective']) {
          update(() {
            invert = mode != 'natural';
            preserve = mode == 'selective';
          });
          await _settle(tester);
          await tester.runAsync(() async {
            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(const ValueKey('photo-capture')),
            );
            final image = await boundary.toImage();
            width = image.width;
            height = image.height;
            captures[mode] = (await image.toByteData())!.buffer.asUint8List();
            final file = File('build/photo-dark-mode/viewer-$mode.png');
            file.parent.createSync(recursive: true);
            file.writeAsBytesSync(
              (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer
                  .asUint8List(),
            );
            image.dispose();
          });
        }
        final masks = <Rect>[];
        await tester.runAsync(() async {
          for (final number in [1, 2]) {
            final analysis = await session.readLocked(
              (pdf) => analyzePhotos(pdf, number),
            );
            masks.addAll(
              analysis.regions.map(
                (region) => photoViewportRect(
                  region,
                  session.lease.document.pages[number - 1],
                  controller.layout.pageLayouts[number - 1],
                  controller.visibleRect,
                ),
              ),
            );
          }
        });
        var restored = 0;
        for (var y = 4; y < height - 4; y += 5) {
          for (var x = 4; x < width - 4; x += 5) {
            final point = Offset((x + .5) / width, (y + .5) / height);
            final inside = masks.any(
              (r) => r.deflate(3 / width).contains(point),
            );
            if (!inside &&
                masks.any((r) => r.inflate(3 / width).contains(point))) {
              continue;
            }
            final offset = (y * width + x) * 4;
            final expected = captures[inside ? 'natural' : 'original']!;
            for (var c = 0; c < 4; c++) {
              expect(
                captures['selective']![offset + c],
                closeTo(expected[offset + c], 3),
                reason:
                    'Production viewer mask or overlay mismatch at $x,$y inside=$inside',
              );
            }
            if (inside &&
                (captures['original']![offset] - expected[offset]).abs() > 10) {
              restored++;
            }
          }
        }
        expect(restored, greaterThan(100));
      }
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await session.close();
        await PdfrxEntryFunctions.instance.stopBackgroundWorker();
      });
      original?.dispose();
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _wait(WidgetTester tester, bool Function() condition) async {
  for (var i = 0; i < 200; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 10));
    if (condition()) return;
  }
  fail('Viewer did not become ready');
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 40; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
}

Future<T> _withPumps<T>(
  WidgetTester tester,
  Future<T> Function() action,
) async {
  var done = false;
  T? result;
  Object? error;
  unawaited(
    action().then(
      (value) {
        result = value;
        done = true;
      },
      onError: (Object e) {
        error = e;
        done = true;
      },
    ),
  );
  await _wait(tester, () => done);
  if (error != null) throw error!;
  return result as T;
}
