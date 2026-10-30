import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:podofo_one/src/dark_mode/photo_filter.dart';
import 'package:podofo_one/src/dark_mode/photo_analysis.dart';
import 'package:podofo_one/src/dark_mode/photo_diagnostics.dart';
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
        await (FontLoader('Urbanist')..addFont(
              rootBundle.load(
                'assets/fonts/Urbanist/static/Urbanist-Regular.ttf',
              ),
            ))
            .load();
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
      var showDiagnostics = false;
      final diagnostics = PhotoDiagnosticsController();
      addTearDown(diagnostics.dispose);
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(fontFamily: 'Urbanist'),
          builder: (context, child) => DefaultTextStyle(
            style: const TextStyle(fontFamily: 'Urbanist', fontSize: 14),
            child: child!,
          ),
          home: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return Padding(
                padding: const EdgeInsets.fromLTRB(33, 17, 41, 29),
                child: RepaintBoundary(
                  key: const ValueKey('photo-capture'),
                  child: PhotoPreservingFilter(
                    showDiagnostics: showDiagnostics,
                    diagnostics: diagnostics,
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
      update(() => showDiagnostics = true);
      await _settle(tester);
      expect(find.byType(PhotoDiagnosticsOverlay), findsOneWidget);
      expect(tester.state(find.byType(PdfViewer)), same(state));
      expect(controller.value, matrix);
      expect(
        await _withPumps(
          tester,
          controller.textSelectionDelegate.getSelectedText,
        ),
        selectedText,
      );
      update(() {
        invert = false;
        preserve = false;
      });
      await _settle(tester);
      expect(
        diagnostics.value!.entries.where((e) => e.reason == 'inversion-off'),
        isNotEmpty,
      );
      expect(
        diagnostics.value!.entries.where(
          (e) => e.status == PhotoDiagnosticStatus.rejected,
        ),
        isNotEmpty,
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
      // Capture the debug overlay on rotated, cropped pages in a spread.
      await tester.runAsync(() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('photo-capture')),
        );
        final image = await boundary.toImage();
        final file = File('build/photo-dark-mode/viewer-diagnostics.png');
        file.parent.createSync(recursive: true);
        file.writeAsBytesSync(
          (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer
              .asUint8List(),
        );
        image.dispose();
      });
      update(() => showDiagnostics = false);
      await _settle(tester);
      expect(find.byType(PhotoDiagnosticsOverlay), findsNothing);
      expect(diagnostics.value, isNull);
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
        update(() => showDiagnostics = true);
        await _settle(tester);
        expect(
          diagnostics.value!.entries.where(
            (e) => e.status == PhotoDiagnosticStatus.preserved,
          ),
          hasLength(2),
        );
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
  testWidgets('dense panels stay preserved through zoom and two-page layout', (
    tester,
  ) async {
    late PdfSession session;
    late ui.FragmentShader original;
    late ui.FragmentProgram selective;
    await tester.runAsync(() async {
      await pdfrxInitialize();
      session = await PdfSession.open(
        'test/fixtures/photo_dark_mode/dense.pdf',
      );
      original = (await ui.FragmentProgram.fromAsset(
        'shaders/invert.frag',
      )).fragmentShader()..setFloat(2, 1);
      selective = await ui.FragmentProgram.fromAsset(
        'shaders/invert_photos.frag',
      );
    });
    final controller = PdfViewerController();
    final diagnostics = PhotoDiagnosticsController();
    var twoPages = false, preserve = true, invert = true, show = true;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return RepaintBoundary(
              key: const ValueKey('dense-capture'),
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
                showDiagnostics: show,
                diagnostics: diagnostics,
                child: PdfViewer(
                  session.lease.reference,
                  controller: controller,
                  params: PdfViewerParams(
                    layoutPages: twoPages ? layoutTwoPages : null,
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
    await _wait(tester, () => controller.isReady);
    await _wait(
      tester,
      () =>
          diagnostics.value?.pages.any(
            (p) => (p.analysis?.pendingCount ?? 0) > 0,
          ) ??
          false,
    );
    unawaited(
      controller.goTo(
        controller.calcMatrixForRect(controller.layout.pageLayouts[1]),
        duration: Duration.zero,
      ),
    );
    await _wait(
      tester,
      () =>
          diagnostics.value?.entries
              .where(
                (e) =>
                    e.pageNumber == 2 &&
                    e.status == PhotoDiagnosticStatus.preserved,
              )
              .length ==
          92,
      attempts: 800,
      details: () =>
          'visible=${controller.visibleRect}; page=${controller.layout.pageLayouts[1]}; ${diagnostics.value?.pages.map((p) => '${p.pageNumber}:pending=${p.analysis?.pendingCount},photos=${p.analysis?.regions.length},preserved=${p.entries.where((e) => e.status == PhotoDiagnosticStatus.preserved).length},reasons=${p.entries.map((e) => e.reason).toSet()}')}',
    );
    expect(
      diagnostics.value!.pages
          .singleWhere((p) => p.pageNumber == 2)
          .analysis!
          .isComplete,
      isTrue,
    );

    final page = controller.layout.pageLayouts[1];
    final zoom = Rect.fromLTWH(
      page.left + page.width * .2,
      page.top + page.height * .2,
      page.width * .5,
      page.height * .5,
    );
    unawaited(
      controller.goTo(
        controller.calcMatrixForRect(zoom),
        duration: Duration.zero,
      ),
    );
    await _settle(tester);
    final rects = diagnostics.value!.entries
        .where((e) => e.status == PhotoDiagnosticStatus.preserved)
        .map((e) => e.rect)
        .toList();
    expect(rects.length, greaterThan(16));
    final captures = <String, Uint8List>{};
    var width = 0, height = 0;
    for (final mode in ['natural', 'original', 'selective']) {
      update(() {
        show = false;
        invert = mode != 'natural';
        preserve = mode == 'selective';
      });
      await _settle(tester);
      await tester.runAsync(() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('dense-capture')),
        );
        final image = await boundary.toImage();
        try {
          width = image.width;
          height = image.height;
          captures[mode] = (await image.toByteData())!.buffer.asUint8List();
          final file = File('build/photo-dark-mode/dense-zoom-$mode.png');
          file.parent.createSync(recursive: true);
          file.writeAsBytesSync(
            (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer
                .asUint8List(),
          );
        } finally {
          image.dispose();
        }
      });
    }
    var insideSamples = 0, outsideSamples = 0;
    for (var y = 4; y < height - 4; y += 7) {
      for (var x = 4; x < width - 4; x += 7) {
        final point = Offset((x + .5) / width, (y + .5) / height);
        final inside = rects.any((r) => r.deflate(4 / width).contains(point));
        if (!inside && rects.any((r) => r.inflate(4 / width).contains(point))) {
          continue;
        }
        final expected = captures[inside ? 'natural' : 'original']!;
        if (inside) {
          insideSamples++;
        } else {
          outsideSamples++;
        }
        final offset = (y * width + x) * 4;
        for (var c = 0; c < 4; c++) {
          expect(
            captures['selective']![offset + c],
            closeTo(expected[offset + c], 3),
            reason: 'zoom xy=$x,$y',
          );
        }
      }
    }
    expect(insideSamples, greaterThan(100));
    expect(outsideSamples, greaterThan(100));
    update(() {
      twoPages = true;
      show = true;
    });
    await _settle(tester);
    final spread = controller.layout.pageLayouts[0].expandToInclude(
      controller.layout.pageLayouts[1],
    );
    unawaited(
      controller.goTo(
        controller.calcMatrixForRect(spread),
        duration: Duration.zero,
      ),
    );
    await _wait(
      tester,
      () =>
          diagnostics.value?.entries
              .where(
                (e) =>
                    e.pageNumber <= 2 &&
                    e.status == PhotoDiagnosticStatus.preserved,
              )
              .length ==
          117,
      attempts: 800,
    );
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await session.close();
      await PdfrxEntryFunctions.instance.stopBackgroundWorker();
    });
    diagnostics.dispose();
    original.dispose();
    expect(tester.takeException(), isNull);
  });
}

Future<void> _wait(
  WidgetTester tester,
  bool Function() condition, {
  String Function()? details,
  int attempts = 200,
}) async {
  for (var i = 0; i < attempts; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 10));
    if (condition()) return;
  }
  fail('Viewer did not become ready: ${details?.call()}');
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
