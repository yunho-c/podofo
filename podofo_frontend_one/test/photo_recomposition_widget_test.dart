import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:podofo_one/src/dark_mode/photo_diagnostics.dart';
import 'package:podofo_one/src/dark_mode/photo_filter.dart';
import 'package:podofo_one/src/dark_mode/photo_override_overlay.dart';
import 'package:podofo_one/src/dark_mode/photo_quality.dart';
import 'package:podofo_one/src/services/pdf_session.dart';

void main() {
  testWidgets(
    'recomposition switches, manual targets, native and live overlay fallbacks',
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
          'test/fixtures/photo_dark_mode/recomposition.pdf',
        );
        original = (await ui.FragmentProgram.fromAsset(
          'shaders/invert.frag',
        )).fragmentShader()..setFloat(2, 1);
        program = await ui.FragmentProgram.fromAsset(
          'shaders/invert_photos.frag',
        );
      });
      final controller = PdfViewerController();
      final overlay = ValueNotifier(false);
      final diagnostics = PhotoDiagnosticsController();
      var mode = PhotoPreservationMode.opaque;
      var outlines = false;
      late StateSetter update;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        overlay.dispose();
        diagnostics.dispose();
        original.dispose();
        await tester.runAsync(() async {
          await session.close();
          await PdfrxEntryFunctions.instance.stopBackgroundWorker();
        });
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(fontFamily: 'Urbanist'),
          home: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return RepaintBoundary(
                key: const ValueKey('capture'),
                child: PhotoPreservingFilter(
                  session: session,
                  revision: session.revision,
                  controller: controller,
                  enabled: true,
                  selective: true,
                  twoPages: false,
                  strength: 1,
                  mode: mode,
                  defaultShader: original,
                  program: program,
                  showDiagnostics: outlines,
                  diagnostics: diagnostics,
                  overlayChanges: overlay,
                  hasForegroundOverlay: () => overlay.value,
                  child: ValueListenableBuilder(
                    valueListenable: overlay,
                    builder: (context, active, _) => Stack(
                      fit: StackFit.expand,
                      children: [
                        PdfViewer(
                          session.lease.reference,
                          controller: controller,
                          initialPageNumber: 9,
                        ),
                        if (active)
                          const Positioned(
                            left: 300,
                            top: 180,
                            width: 160,
                            height: 160,
                            child: ColoredBox(color: Color(0x880000ff)),
                          ),
                      ],
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
          .entries;
      Future<void> waitFor(bool Function() condition) async {
        for (var i = 0; i < 500; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 20));
          if (condition()) return;
        }
        fail('Viewer did not finish photo analysis');
      }

      Future<void> settle() async {
        for (var i = 0; i < 80; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 20));
        }
      }

      Future<List<int>> capture({bool wait = true, String? name}) async {
        if (wait) await settle();
        return (await tester.runAsync(() async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('capture')),
          );
          final image = await boundary.toImage();
          try {
            if (name != null) {
              final file = File('build/photo-dark-mode/$name.png')
                ..parent.createSync(recursive: true);
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

      await waitFor(() => controller.isReady && entries().isNotEmpty);
      unawaited(
        controller.goTo(
          controller.calcMatrixForFit(pageNumber: 9)!,
          duration: Duration.zero,
        ),
      );
      await settle();
      final entry = entries().single;
      expect(entry.automatic, isFalse);
      session.photoOverrides.toggle(entry.target, automatic: false);
      final strict = await capture();
      final state = tester.state(find.byType(PdfViewer));
      final matrix = controller.value.clone();
      update(() => mode = PhotoPreservationMode.recomposeWhite);
      final corrected = await capture(name: 'recomposition-viewer');
      expect(corrected, isNot(strict));
      expect(entries().single.target, entry.target);
      expect(session.photoOverrides.count, 1);
      expect(tester.state(find.byType(PdfViewer)), same(state));
      expect(controller.value, matrix);
      overlay.value = true;
      await tester.pump();
      final immediate = await capture(wait: false);
      final settled = await capture();
      // On the first overlay frame the stale correction is already gone. While
      // its fallback mask builds, the default dark transform may temporarily win.
      expect(immediate, isNot(corrected));
      update(() => mode = PhotoPreservationMode.opaque);
      final strictOverlay = await capture();
      expect(settled, strictOverlay);
      overlay.value = false;
      update(() => mode = PhotoPreservationMode.recomposeWhite);
      expect(await capture(), corrected);
      for (final m in [
        PhotoPreservationMode.nonzero,
        PhotoPreservationMode.recomposeWhite,
        PhotoPreservationMode.opaque,
      ]) {
        update(() => mode = m);
        await tester.pump();
      }
      expect(await capture(), strict);
      expect(session.photoOverrides.count, 1);

      // Native annotations and earlier artwork must produce byte-identical
      // opaque-only output in the actual viewer, not just a diagnostic flag.
      for (final number in [3, 4, 7]) {
        unawaited(
          controller.goTo(
            controller.calcMatrixForFit(pageNumber: number)!,
            duration: Duration.zero,
          ),
        );
        final baseline = await capture();
        update(() => mode = PhotoPreservationMode.recomposeWhite);
        expect(await capture(), baseline, reason: 'page $number');
        update(() => mode = PhotoPreservationMode.opaque);
      }
      unawaited(
        controller.goTo(
          controller.calcMatrixForFit(pageNumber: 9)!,
          duration: Duration.zero,
        ),
      );
      update(() {
        mode = PhotoPreservationMode.recomposeWhite;
        outlines = true;
      });
      await waitFor(
        () =>
            diagnostics.value?.entries.any(
              (e) =>
                  e.pageNumber == 9 &&
                  e.recomposing &&
                  e.status == PhotoDiagnosticStatus.preserved,
            ) ??
            false,
      );
      overlay.value = true;
      await waitFor(
        () =>
            diagnostics.value?.entries.any(
              (e) =>
                  e.pageNumber == 9 &&
                  e.recompositionFallback == 'viewer-overlay-active' &&
                  !e.recomposing,
            ) ??
            false,
      );
      await settle();
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );
}
