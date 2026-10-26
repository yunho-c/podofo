import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:podofo_one/main.dart';
import 'package:podofo_one/objectbox.g.dart';
import 'package:podofo_one/src/data/document_entity.dart';
import 'package:podofo_one/src/data/objectbox.dart';
import 'package:podofo_one/src/editing/annotation_edit.dart';
import 'package:podofo_one/src/narration/narration_controller.dart';
import 'package:podofo_one/src/providers/data_provider.dart';
import 'package:podofo_one/src/providers/document_provider.dart';
import 'package:podofo_one/src/providers/narration_provider.dart';
import 'package:podofo_one/src/providers/user_state_provider.dart';
import 'package:podofo_one/src/services/pdf_highlights.dart';
import 'package:podofo_one/src/services/pdf_session.dart';
import 'package:podofo_one/src/widgets/components/highlight_palette.dart';
import 'package:podofo_one/src/widgets/components/pdf_selection_menu.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures/annotation_pdf.dart';
import 'fixtures/spaced_text_pdf.dart';
import 'reader_widget_test.dart' show waitForNative, captureReader;
import 'support/fake_narrator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final rotation in [0, 90, 180, 270]) {
    testWidgets('right-click edits cropped text markup at $rotation degrees', (
      tester,
    ) async {
      await tester.runAsync(() async {
        for (final font in {
          'Urbanist': 'assets/fonts/Urbanist/static/Urbanist-Regular.ttf',
          'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
          'packages/shadcn_flutter/RadixIcons':
              'packages/shadcn_flutter/lib/icons/RadixIcons.otf',
          'packages/font_awesome_flutter/FontAwesomeSolid': 'packages/font_awesome_flutter/lib/fonts/Font-Awesome-7-Free-Solid-900.otf',
        }.entries) {
          await (FontLoader(
            font.key,
          )..addFont(rootBundle.load(font.value))).load();
        }
      });
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final temporary = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('podofo-context-'),
      ))!;
      await tester.runAsync(() => pdfrxInitialize(tmpPath: temporary.path));
      final file = File('${temporary.path}/context.pdf')
        ..writeAsBytesSync(spacedTextPdf(cropped: true, rotation: rotation));
      final store = Store(
        getObjectBoxModel(),
        directory: '${temporary.path}/db',
      );
      store.box<DocumentEntity>().put(DocumentEntity(filePath: file.path));
      store.box<UserState>().put(UserState()..autoSaveEnabled = false);
      final narration = NarrationController(
        open: (_) async => FakeNarratorSession(),
      );
      final container = ProviderContainer(
        overrides: [
          objectboxProvider.overrideWithValue(ObjectBox(store)),
          narrationControllerProvider.overrideWithValue(narration),
        ],
      );
      try {
        await tester.pumpWidget(
          RepaintBoundary(
            key: const ValueKey('reader-capture'),
            child: UncontrolledProviderScope(
              container: container,
              child: const MyApp(),
            ),
          ),
        );
        await waitForNative(
          tester,
          () => container.read(pdfTextSearcherProvider) != null,
        );

        final document = container.read(currentDocumentProvider)!;
        final session = document.session;
        final notifier = container.read(loadedDocumentsProvider.notifier);
        final viewer = container.read(pdfViewerControllerProvider);
        const rects = [PdfRect(30, 135, 110, 110), PdfRect(170, 135, 230, 110)];
        await tester.runAsync(
          () => notifier.highlight(document, [
            const HighlightRegion(1, rects),
          ], 0x66ffeb3b),
        );
        await tester.pump();

        final original = (await tester.runAsync(session.annotations))!.single;
        final defaultColor = container
            .read(userStateNotifierProvider)
            .highlightColor;
        Offset screen(double x, double y) => viewer.documentToGlobal(
          PdfRect(x, y, x, y)
              .toRectInDocument(
                page: document.pdfDocument.pages.first,
                pageRect: viewer.layout.pageLayouts.first,
              )
              .center,
        )!;

        await viewer.setZoom(
          viewer.layout.pageLayouts.first.center,
          1.8,
          duration: Duration.zero,
        );
        await tester.pump();

        await tester.tapAt(screen(60, 120), kind: PointerDeviceKind.mouse);
        await tester.pump();
        expect(find.text('Remove highlight'), findsNothing);

        // A pre-existing text selection must never turn recoloring into
        // another highlight creation.
        final text = (await tester.runAsync(
          () => document.pdfDocument.pages.first.loadStructuredText(),
        ))!;
        await viewer.textSelectionDelegate.setTextSelectionPointRange(
          PdfTextSelectionRange.fromPoints(
            PdfTextSelectionPoint(text, 0),
            PdfTextSelectionPoint(text, text.fullText.length - 1),
          ),
        );
        await tester.pump();
        Future<void> menu(double x, double y) async {
          await tester.tapAt(
            screen(x, y),
            buttons: kSecondaryMouseButton,
            kind: PointerDeviceKind.mouse,
          );
          await tester.pump();
          await waitForNative(
            tester,
            () => find.text('Remove highlight').evaluate().isNotEmpty,
          );
          await tester.pump();
        }

        await menu(60, 120);
        expect(find.text('Copy'), findsOneWidget);
        expect(find.byType(HighlightPalette), findsOneWidget);
        expect(
          tester
              .widget<HighlightPalette>(find.byType(HighlightPalette))
              .selectedColor,
          '#66ffeb3b',
        );
        if (rotation == 0) {
          await captureReader(tester, 'highlight-edit-context-menu');
        }
        final palette = container
            .read(userStateNotifierProvider)
            .highlightColorPalette;
        final next = palette.indexWhere((c) => c != '#66ffeb3b');
        final revision = session.revision;
        await tester.tap(find.byKey(ValueKey('highlight-color-$next')));
        await waitForNative(tester, () => session.revision > revision);

        final recolored = (await tester.runAsync(session.annotations))!.single;
        expect(recolored.id, original.id);
        expect(
          recolored.argb,
          int.parse(palette[next].substring(1), radix: 16),
        );
        expect(
          container.read(userStateNotifierProvider).highlightColor,
          defaultColor,
        );
        expect(session.undoLabel, 'Change highlight color');
        await tester.runAsync(() => notifier.undo(document));
        expect(
          (await tester.runAsync(session.annotations))!.single.argb,
          original.argb,
        );
        await tester.runAsync(() => notifier.redo(document));
        await tester.pump();
        await menu(190, 120);
        final deleteRevision = session.revision;
        await tester.tap(find.text('Remove highlight'));
        await waitForNative(tester, () => session.revision > deleteRevision);
        expect(await tester.runAsync(session.annotations), isEmpty);
        await tester.runAsync(() => notifier.undo(document));
        await tester.pump();

        await menu(60, 120);
        final unchangedRevision = session.revision;
        await tester.tap(find.byKey(ValueKey('highlight-color-$next')));
        await tester.runAsync(session.waitForIdle);
        await tester.pump();
        expect(session.revision, unchangedRevision);
        await menu(60, 120);
        await tester.tapAt(const Offset(15, 850));
        await tester.pump();
        expect(find.byType(PdfSelectionMenu), findsNothing);
        await menu(60, 120);
        // Reopening elsewhere while a menu is still open updates its target
        // and gives the new menu keyboard focus as well.
        await menu(190, 120);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        await tester.pump();
        expect(find.byType(PdfSelectionMenu), findsNothing);
        // The gap between quads is not part of the highlight.
        await tester.tapAt(
          screen(140, 120),
          buttons: kSecondaryMouseButton,
          kind: PointerDeviceKind.mouse,
        );
        await waitForNative(
          tester,
          () => find.byType(PdfSelectionMenu).evaluate().isNotEmpty,
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
        expect(find.text('Remove highlight'), findsNothing);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        await tester.pump();
        // A menu opened before another edit cannot act on a newer model.

        await menu(60, 120);
        await tester.runAsync(
          () => notifier.recolorHighlights(
            document,
            {original.id},
            0x66abcdef,
            session.revision,
          ),
        );
        await tester.pump();
        expect(find.text('Remove highlight'), findsNothing);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        await tester.pump();
        await tester.runAsync(() => notifier.saveDocument(document));
        await tester.runAsync(() async {
          final reopened = await PdfSession.open(file.path);
          try {
            final a = (await reopened.annotations()).single;
            expect(a.pdfName, original.pdfName);
            expect(a.argb, 0x66abcdef);
            expect(a.canEdit, true);
          } finally {
            await reopened.close(discard: true);
          }
        });
        // Underline the selected text even when it already has a highlight.
        await viewer.textSelectionDelegate.setTextSelectionPointRange(
          PdfTextSelectionRange.fromPoints(
            PdfTextSelectionPoint(text, 0),
            PdfTextSelectionPoint(text, text.fullText.length - 1),
          ),
        );
        await tester.pump();
        await menu(60, 120);
        final beforeUnderline = session.revision;
        final viewport = viewer.value.clone();
        await tester.tap(find.text('Underline'));
        await waitForNative(tester, () => session.revision > beforeUnderline);
        final marks = (await tester.runAsync(session.annotations))!;
        expect(marks, hasLength(2));
        final underline = marks.singleWhere(
          (a) => a.kind == AnnotationKind.underline,
        );
        expect(underline.argb, 0xffff0000);
        expect(session.undoLabel, 'Add underline');
        expect(
          container.read(userStateNotifierProvider).highlightColor,
          defaultColor,
        );
        expect(viewer.textSelectionDelegate.hasSelectedText, false);
        Future<void> expectUnderlineVisible(bool visible) async {
          var redPixels = 0;
          for (var attempt = 0; attempt < 60; attempt++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 20)),
            );
            await tester.pump(const Duration(milliseconds: 20));
            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(const ValueKey('reader-capture')),
            );
            redPixels = (await tester.runAsync(() async {
              final image = await boundary.toImage();
              try {
                final bytes = (await image.toByteData(
                  format: ui.ImageByteFormat.rawRgba,
                ))!;
                var red = 0;
                for (var i = 0; i < bytes.lengthInBytes; i += 4) {
                  if (bytes.getUint8(i) > 180 &&
                      bytes.getUint8(i + 1) < 120 &&
                      bytes.getUint8(i + 2) < 120) {
                    red++;
                  }
                }
                return red;
              } finally {
                image.dispose();
              }
            }))!;
            if (visible ? redPixels > 30 : redPixels == 0) break;
          }
          expect(
            redPixels,
            visible ? greaterThan(30) : 0,
            reason: 'The underline must refresh without scrolling or zooming',
          );
          expect(viewer.value, viewport);
        }

        await expectUnderlineVisible(true);
        if (rotation == 0) {
          await captureReader(tester, 'underline-created');
        }
        final quad = underline.quads.first;
        await tester.tapAt(
          screen((quad[0] + quad[2]) / 2, (quad[1] + quad[5]) / 2),
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryMouseButton,
        );
        await waitForNative(
          tester,
          () => find.byType(HighlightPalette).evaluate().isNotEmpty,
        );
        expect(find.byType(HighlightPalette), findsOneWidget);
        expect(find.text('Highlight'), findsOneWidget);
        expect(find.text('Underline'), findsNothing);
        expect(find.text('Remove underline'), findsOneWidget);
        expect(find.text('Remove highlight'), findsNothing);
        if (rotation == 0) {
          await captureReader(tester, 'underline-context-menu');
        }
        final beforeAddition = session.revision;
        await tester.tap(find.byKey(ValueKey('highlight-color-$next')));
        await waitForNative(tester, () => session.revision > beforeAddition);
        final withHighlight = (await tester.runAsync(session.annotations))!;
        expect(withHighlight, hasLength(3));
        final added = withHighlight.last;
        expect(added.kind, AnnotationKind.highlight);
        expect(added.argb, int.parse(palette[next].substring(1), radix: 16));
        expect(added.quads, underline.quads);
        expect(
          withHighlight.singleWhere((a) => a.id == underline.id).argb,
          0xffff0000,
        );
        expect(session.undoLabel, 'Add highlight');
        expect(
          container.read(userStateNotifierProvider).highlightColor,
          defaultColor,
        );
        await expectUnderlineVisible(true);
        await tester.runAsync(() => notifier.undo(document));
        expect(
          (await tester.runAsync(session.annotations))!.map((a) => a.id),
          marks.map((a) => a.id),
        );
        await tester.runAsync(() => notifier.redo(document));
        expect((await tester.runAsync(session.annotations))!.last.id, added.id);
        await tester.runAsync(() => notifier.undo(document));
        await tester.runAsync(() => notifier.saveDocument(document));
        await tester.runAsync(() async {
          final reopened = await PdfSession.open(file.path);
          try {
            final a = (await reopened.annotations()).singleWhere(
              (a) => a.kind == AnnotationKind.underline,
            );
            expect(a.argb, 0xffff0000);
            expect(a.canEdit, true);
          } finally {
            await reopened.close(discard: true);
          }
        });
        if (rotation == 0) {
          await tester.tap(find.byTooltip('Annotations'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 250));
          await waitForNative(
            tester,
            () => find.byTooltip('Remove underline').evaluate().isNotEmpty,
          );
          final sidebarRevision = session.revision;
          await tester.tap(find.byTooltip('Remove underline'));
          await waitForNative(tester, () => session.revision > sidebarRevision);
          List<AnnotationRecord>? afterSidebarRemoval;
          session.annotations().then(
            (records) => afterSidebarRemoval = records,
          );
          await waitForNative(tester, () => afterSidebarRemoval != null);
          expect(afterSidebarRemoval!.single.kind, AnnotationKind.highlight);
          await menu(60, 120);
          // Switching tabs must dismiss the captured target.
          final foreignFile = File('${temporary.path}/foreign.pdf')
            ..writeAsBytesSync(annotationPdf(relationships: false));
          expect(
            await tester.runAsync(() => notifier.addDocument(foreignFile.path)),
            true,
          );
          await waitForNative(
            tester,
            () =>
                container.read(currentDocumentProvider)?.filePath ==
                    foreignFile.resolveSymbolicLinksSync() &&
                container.read(pdfTextSearcherProvider) != null,
          );
          expect(find.text('Remove highlight'), findsNothing);
          final foreign = container.read(currentDocumentProvider)!;
          final foreignViewer = container.read(pdfViewerControllerProvider);
          await foreignViewer.setZoom(
            foreignViewer.layout.pageLayouts.first.center,
            1.8,
            duration: Duration.zero,
          );
          await tester.pump();
          Future<void> foreignMenu({bool readOnly = true}) async {
            final point = foreignViewer.documentToGlobal(
              const PdfRect(60, 110, 60, 110)
                  .toRectInDocument(
                    page: foreign.pdfDocument.pages.first,
                    pageRect: foreignViewer.layout.pageLayouts.first,
                  )
                  .center,
            )!;
            await tester.tapAt(
              point,
              buttons: kSecondaryMouseButton,
              kind: PointerDeviceKind.mouse,
            );
            await waitForNative(
              tester,
              () => find
                  .text(
                    readOnly
                        ? 'This highlight is read-only'
                        : 'Remove highlight',
                  )
                  .evaluate()
                  .isNotEmpty,
            );
            await tester.pump();
          }

          await foreignMenu();
          expect(find.text('This highlight is read-only'), findsOneWidget);
          expect(find.text('Remove highlight'), findsNothing);
          expect(find.text('Remove underline'), findsNothing);
          expect(find.byType(HighlightPalette), findsNothing);
          expect(foreign.session.dirty, false);
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pump();
          await tester.runAsync(
            () => notifier.highlight(foreign, [
              const HighlightRegion(1, [PdfRect(20, 120, 130, 100)]),
            ], 0x66abcdef),
          );
          await tester.pump();
          await foreignMenu(readOnly: false);
          expect(find.text('This highlight is read-only'), findsNothing);
          expect(find.byTooltip('Current highlight color'), findsOneWidget);
          final revision = foreign.session.revision;
          await tester.tap(find.text('Remove highlight'));
          await waitForNative(
            tester,
            () => foreign.session.revision > revision,
          );
          final remaining = (await tester.runAsync(
            foreign.session.annotations,
          ))!;
          expect(remaining, hasLength(3));
          expect(remaining.every((a) => !a.owned), true);
          await foreignMenu();
          expect(find.text('This highlight is read-only'), findsOneWidget);
          expect(find.text('Remove highlight'), findsNothing);
        }
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
        await tester.runAsync(narration.close);
        store.close();
        await tester.runAsync(() async {
          await PdfrxEntryFunctions.instance.stopBackgroundWorker();
          await temporary.delete(recursive: true);
        });
      }
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  }
}
