import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';

import 'fixtures/pdf_fixture.dart';

const _duration = Duration(milliseconds: 120);
const _fieldKey = ValueKey('other-focus');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(pdfrxInitialize);

  for (final entry in {
    LogicalKeyboardKey.arrowDown: const Offset(0, -1),
    LogicalKeyboardKey.arrowUp: const Offset(0, 1),
    LogicalKeyboardKey.arrowLeft: const Offset(1, 0),
    LogicalKeyboardKey.arrowRight: const Offset(-1, 0),
  }.entries) {
    testWidgets('${entry.key.keyLabel} eases to the existing step distance', (
      tester,
    ) async {
      final viewer = await _mount(tester);
      final origin = _translation(viewer);
      final step = entry.value * 25 * viewer.currentZoom;
      await tester.sendKeyEvent(entry.key);
      expect(_translation(viewer), origin);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      final progress = (_translation(viewer) - origin).distance;
      expect(progress, greaterThan(0));
      expect(progress, lessThan(step.distance));
      await tester.pump(const Duration(milliseconds: 80));
      _expectOffset(_translation(viewer), origin + step);
      final settled = viewer.value.clone();
      var changes = 0;
      viewer.addListener(() => changes++);
      await tester.pump(const Duration(seconds: 1));
      expect(viewer.value, settled);
      expect(changes, 0, reason: 'No animation updates after the endpoint');
    });
  }

  testWidgets('held keys accumulate every repeat and reverse promptly', (
    tester,
  ) async {
    final viewer = await _mount(tester);
    final origin = _translation(viewer);
    final step = 25 * viewer.currentZoom;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 30));
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump(_duration);
    _expectOffset(_translation(viewer), origin - Offset(0, 5 * step));

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    final beforeReverse = _translation(viewer);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(_translation(viewer).dy, greaterThan(beforeReverse.dy));
    await tester.pump(const Duration(milliseconds: 100));
    _expectOffset(_translation(viewer), beforeReverse + Offset(0, step));
  });

  testWidgets('edge repeats do not extend settling or schedule idle frames', (
    tester,
  ) async {
    final viewer = await _mount(tester);
    await viewer.goToPage(pageNumber: 1, duration: Duration.zero);
    await tester.pumpAndSettle();
    // Start just below the top boundary, with one step enough to reach it.
    final top = viewer.makeMatrixInSafeRange(
      viewer.value.clone()..translateByDouble(0, 10000, 0, 1),
      forceClamp: true,
    );
    viewer.value = top.clone()..translateByDouble(0, -5, 0, 1);
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 30));
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowUp);
    }
    expect(viewer.value, top);
    await tester.pumpAndSettle();
    var changes = 0;
    viewer.addListener(() => changes++);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowUp);
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.pump(const Duration(seconds: 1));
    expect(changes, 0);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowUp);
  });

  for (final reducedMotion in [false, true]) {
    testWidgets(
      reducedMotion
          ? 'Reduce Motion skips easing'
          : 'zero duration keeps instant navigation',
      (tester) async {
        if (reducedMotion) {
          tester.binding.platformDispatcher.accessibilityFeaturesTestValue =
              const FakeAccessibilityFeatures(disableAnimations: true);
          addTearDown(
            tester
                .binding
                .platformDispatcher
                .clearAccessibilityFeaturesTestValue,
          );
        }
        final viewer = await _mount(
          tester,
          duration: reducedMotion ? _duration : Duration.zero,
        );
        final origin = _translation(viewer);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        _expectOffset(
          _translation(viewer),
          origin - Offset(0, 25 * viewer.currentZoom),
        );
        final destination = viewer.value.clone();
        await tester.pump(_duration);
        expect(viewer.value, destination);
      },
    );
  }

  for (final interruption in [
    'wheel',
    'pointer',
    'controller',
    'navigation',
    'focus',
  ]) {
    testWidgets('$interruption takes over an unfinished arrow scroll', (
      tester,
    ) async {
      final viewer = await _mount(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      final before = _translation(viewer);
      switch (interruption) {
        case 'wheel':
          await tester.sendEventToBinding(
            PointerScrollEvent(
              position: tester.getCenter(find.byType(PdfViewer)),
              scrollDelta: const Offset(0, -50),
            ),
          );
          expect(_translation(viewer).dy, greaterThan(before.dy));
        case 'pointer':
          final pointer = await tester.startGesture(
            tester.getCenter(find.byType(PdfViewer)),
            kind: PointerDeviceKind.mouse,
          );
          await pointer.up();
        case 'controller':
          viewer.value = viewer.value.clone()..translateByDouble(10, 15, 0, 1);
        case 'navigation':
          var navigated = false;
          final navigation = viewer
              .goToPage(
                pageNumber: 3,
                duration: const Duration(milliseconds: 100),
              )
              .then((_) => navigated = true);
          await _wait(tester, () => navigated);
          await navigation;
          expect(viewer.pageNumber, 3);
        case 'focus':
          await tester.tap(find.byKey(_fieldKey));
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      }
      final takenOver = viewer.value.clone();
      await tester.pump(const Duration(milliseconds: 300));
      expect(viewer.value, takenOver);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'replacement navigation completes canceled futures without stale listeners',
    (tester) async {
      final viewer = await _mount(tester);
      var completed = 0;
      final first = viewer.goToPage(pageNumber: 1).then((_) => completed++);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      await first;
      expect(completed, 1);
      expect(
        viewer.pageNumber,
        2,
        reason: 'Canceled page targets are not published',
      );
      // A second press in the same frame must also cancel its predecessor cleanly.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      await tester.pump(_duration);
      final settled = viewer.value.clone();
      await tester.pump(const Duration(seconds: 1));
      expect(viewer.value, settled);
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await _wait(tester, () => viewer.pageNumber == 3);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('scroll frames reuse images and refine only after settling', (
    tester,
  ) async {
    var renders = 0;
    final viewer = await _mount(
      tester,
      viewportRenderer: (_, _) async {
        renders++;
        return null;
      },
    );
    final initialRenders = renders;
    final origin = _translation(viewer);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    // Small steps keep the same page visible while exceeding the render delay.
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 24));
      expect(renders, initialRenders);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump(_duration);
    expect(_translation(viewer).dy, lessThan(origin.dy));
    expect(renders, initialRenders);
    await tester.pump(const Duration(milliseconds: 149));
    expect(renders, initialRenders);
    await tester.pump(const Duration(milliseconds: 1));
    await _wait(tester, () => _fullyRendered(viewer));
    expect(renders, initialRenders + 1);
    await tester.pump(const Duration(seconds: 1));
    expect(renders, initialRenders + 1);
  });

  testWidgets('unmounting during a scroll disposes its ticker', (tester) async {
    await _mount(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });
}

Offset _translation(PdfViewerController viewer) {
  final value = viewer.value.getTranslation();
  return Offset(value.x, value.y);
}

void _expectOffset(Offset actual, Offset expected) {
  expect(actual.dx, closeTo(expected.dx, 1e-6));
  expect(actual.dy, closeTo(expected.dy, 1e-6));
}

bool _fullyRendered(PdfViewerController viewer) =>
    viewer.renderingStatus.value.isNotEmpty &&
    viewer.renderingStatus.value.every(
      (page) => page.mode == PdfPageRenderMode.fullResolution,
    );

Future<PdfViewerController> _mount(
  WidgetTester tester, {
  Duration duration = _duration,
  Future<ui.Image?> Function(PdfPage, PdfViewportRenderRequest)?
  viewportRenderer,
}) async {
  final document = (await tester.runAsync(
    () => PdfDocument.openData(
      pdfFixture(rotatedPageDegrees: 0),
      useProgressiveLoading: false,
    ),
  ))!;
  final viewer = PdfViewerController();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(document.dispose);
  });
  await tester.pumpWidget(
    MaterialApp(
      home: Center(
        child: SizedBox(
          width: 400,
          height: 440,
          child: Column(
            children: [
              const SizedBox(
                height: 40,
                child: Material(child: TextField(key: _fieldKey)),
              ),
              Expanded(
                child: PdfViewer(
                  PdfDocumentRefDirect(document, autoDispose: false),
                  controller: viewer,
                  initialPageNumber: 2,
                  params: PdfViewerParams(
                    arrowKeyScrollDuration: duration,
                    scrollByArrowKey: viewportRenderer == null ? 25 : 2,
                    renderAtDisplayScale: true,
                    viewportRenderer: viewportRenderer,
                    behaviorControlParams: const PdfViewerBehaviorControlParams(
                      partialImageLoadingDelay: Duration(milliseconds: 150),
                    ),
                    textSelectionParams: const PdfTextSelectionParams(
                      enabled: false,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await _wait(tester, () => viewer.isReady);
  await viewer.goTo(
    viewer.calcMatrixFor(viewer.layout.pageLayouts[1].center, zoom: 2),
    duration: Duration.zero,
  );
  viewer.requestFocus();
  await _wait(tester, () => _fullyRendered(viewer));
  await tester.pumpAndSettle();
  expect(viewer.focusNode?.hasPrimaryFocus, isTrue);
  return viewer;
}

Future<void> _wait(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 200; i++) {
    await tester.pump(const Duration(milliseconds: 20));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    if (ready()) return;
  }
  fail('Timed out waiting for the PDF viewer');
}
