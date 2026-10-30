import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:podofo_one/src/dark_mode/photo_filter.dart';
import 'package:podofo_one/src/dark_mode/photo_override_overlay.dart';
import 'package:podofo_one/src/services/pdf_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Alt outlines are temporary, focus-safe and intercept only panel taps',
    (tester) async {
      var enabled = false, toggles = 0, pdfTaps = 0;
      late StateSetter update;
      final controller = PdfViewerController();
      const entry = PhotoOverrideEntry(
        target: 'photo',
        rect: Rect.fromLTRB(.2, .2, .6, .6),
        automatic: true,
        override: null,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return Stack(
                children: [
                  Positioned.fill(
                    child: GestureDetector(
                      onTap: () => pdfTaps++,
                      behavior: HitTestBehavior.opaque,
                    ),
                  ),
                  Positioned.fill(
                    child: PhotoOverrideOverlay(
                      enabled: enabled,
                      entries: const [entry],
                      controller: controller,
                      onToggle: (_) => toggles++,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      );
      final panel = find.byKey(const ValueKey('photo-override-photo'));
      expect(panel, findsNothing);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();
      expect(panel, findsNothing);
      update(() => enabled = true);
      await tester.pump();
      expect(panel, findsOneWidget);
      await tester.tap(panel);
      expect(toggles, 1);
      expect(pdfTaps, 0);
      await tester.tapAt(const Offset(20, 20));
      expect(pdfTaps, 1);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();
      expect(panel, findsNothing);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altRight);
      await tester.pump();
      expect(panel, findsOneWidget);
      tester.binding.handleViewFocusChanged(
        ui.ViewFocusEvent(
          viewId: tester.view.viewId,
          state: ui.ViewFocusState.unfocused,
          direction: ui.ViewFocusDirection.undefined,
        ),
      );
      await tester.pump();
      expect(panel, findsNothing);
      tester.binding.handleViewFocusChanged(
        ui.ViewFocusEvent(
          viewId: tester.view.viewId,
          state: ui.ViewFocusState.focused,
          direction: ui.ViewFocusDirection.undefined,
        ),
      );
      await tester.pump();
      expect(
        panel,
        findsNothing,
        reason: 'Focus gain cannot resurrect a stale modifier',
      );
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altRight);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();
      final down = await tester.startGesture(
        tester.getCenter(panel),
        kind: PointerDeviceKind.mouse,
      );
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();
      await down.up();
      expect(
        toggles,
        1,
        reason: 'Releasing Alt cancels an unfinished override click',
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(panel, findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'modifier clicks change actual rotated-page pixels and restore Automatic',
    (tester) async {
      late PdfSession session;
      late ui.FragmentShader original;
      late ui.FragmentProgram program;
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
        original = (await ui.FragmentProgram.fromAsset(
          'shaders/invert.frag',
        )).fragmentShader()..setFloat(2, 1);
        program = await ui.FragmentProgram.fromAsset(
          'shaders/invert_photos.frag',
        );
      });
      final controller = PdfViewerController();
      var enabled = true, selective = true, pdfDowns = 0;
      late StateSetter update;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        original.dispose();
        await tester.runAsync(() async {
          await session.close();
          await PdfrxEntryFunctions.instance.stopBackgroundWorker();
        });
      });
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
                padding: const EdgeInsets.fromLTRB(31, 17, 43, 29),
                child: RepaintBoundary(
                  key: const ValueKey('override-capture'),
                  child: PhotoPreservingFilter(
                    session: session,
                    revision: session.revision,
                    controller: controller,
                    enabled: enabled,
                    selective: selective,
                    twoPages: false,
                    strength: 1,
                    defaultShader: original,
                    program: program,
                    child: Listener(
                      onPointerDown: (_) => pdfDowns++,
                      child: PdfViewer(
                        session.lease.reference,
                        controller: controller,
                        initialPageNumber: 2,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      );
      List<PhotoOverrideEntry> entries() => tester
          .widget<PhotoOverrideOverlay>(find.byType(PhotoOverrideOverlay))
          .entries
          .where((e) => (jsonDecode(e.target) as List)[1] == 2)
          .toList();
      await _wait(
        tester,
        () =>
            controller.isReady &&
            entries().any((e) => e.automatic) &&
            entries().any((e) => !e.automatic),
      );
      final photo = entries().firstWhere((e) => e.automatic);
      final plot = entries().firstWhere((e) => !e.automatic);
      final state = tester.state(find.byType(PdfViewer));
      final matrix = controller.value.clone();
      var width = 0, height = 0;
      Future<Uint8List> capture({String? name}) async {
        await _settle(tester);
        return (await tester.runAsync(() async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('override-capture')),
          );
          final image = await boundary.toImage();
          width = image.width;
          height = image.height;
          try {
            if (name != null) {
              final file = File('build/photo-dark-mode/$name.png');
              file.parent.createSync(recursive: true);
              file.writeAsBytesSync(
                (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer
                    .asUint8List(),
              );
            }
            return (await image.toByteData())!.buffer.asUint8List();
          } finally {
            image.dispose();
          }
        }))!;
      }

      void matchesRegion(Uint8List actual, Uint8List expected, Rect rect) {
        var samples = 0;
        for (
          var y = (rect.top * height).ceil() + 5;
          y < rect.bottom * height - 5;
          y += 7
        ) {
          for (
            var x = (rect.left * width).ceil() + 5;
            x < rect.right * width - 5;
            x += 7
          ) {
            final offset = (y * width + x) * 4;
            for (var c = 0; c < 4; c++) {
              expect(actual[offset + c], closeTo(expected[offset + c], 3));
            }
            samples++;
          }
        }
        expect(samples, greaterThan(20));
      }

      update(() => enabled = false);
      final natural = await capture();
      update(() {
        enabled = true;
        selective = false;
      });
      final dark = await capture();
      update(() => selective = true);
      final automatic = await capture();
      matchesRegion(automatic, natural, photo.rect);
      matchesRegion(automatic, dark, plot.rect);
      Future<void> click(PhotoOverrideEntry entry) async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
        await tester.pump();
        await tester.tap(
          find.byKey(ValueKey('photo-override-${entry.target}')),
          kind: PointerDeviceKind.mouse,
        );
        await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
        await tester.pump();
      }

      await click(photo);
      expect(session.photoOverrides.decision(photo.target), false);
      matchesRegion(await capture(), dark, photo.rect);
      await click(plot);
      expect(session.photoOverrides.decision(plot.target), true);
      final overridden = await capture(name: 'photo-overrides-applied');
      matchesRegion(overridden, dark, photo.rect);
      matchesRegion(overridden, natural, plot.rect);
      expect(
        pdfDowns,
        0,
        reason: 'Override taps never reach PDF selection/link handling',
      );
      expect(session.dirty, isFalse);
      expect(tester.state(find.byType(PdfViewer)), same(state));
      expect(controller.value, matrix);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.altRight);
      await tester.pump();
      await capture(name: 'photo-overrides-option-outlines');
      final position = tester.getCenter(
        find.byKey(ValueKey('photo-override-${photo.target}')),
      );
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: position,
          scrollDelta: const Offset(0, 40),
        ),
      );
      await tester.pump();
      expect(
        controller.value,
        isNot(matrix),
        reason: 'Wheel scrolling still reaches the viewer',
      );
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altRight);
      unawaited(controller.goTo(matrix, duration: Duration.zero));
      await _settle(tester);
      await click(photo);
      await click(plot);
      expect(session.photoOverrides.count, 0);
      final reset = await capture();
      matchesRegion(reset, natural, photo.rect);
      matchesRegion(reset, dark, plot.rect);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _wait(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 300; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 10));
    if (ready()) return;
  }
  fail('Photo override UI did not become ready');
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 15; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
}
