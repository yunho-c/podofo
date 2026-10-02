import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:podofo_one/main.dart';
import 'package:podofo_one/objectbox.g.dart';
import 'package:podofo_one/src/data/document_entity.dart';
import 'package:podofo_one/src/data/objectbox.dart';
import 'package:podofo_one/src/providers/data_provider.dart';
import 'package:podofo_one/src/providers/document_provider.dart';
import 'package:podofo_one/src/providers/user_state_provider.dart';
import 'package:podofo_one/src/providers/theme_provider.dart';
import 'package:podofo_one/src/services/pdf_highlights.dart';
import 'package:podofo_one/src/widgets/components/highlight_palette.dart';
import 'package:podofo_one/src/widgets/components/pdf_selection_menu.dart';
import 'package:podofo_one/src/widgets/components/thumbnail_card.dart';
import 'package:podofo_one/src/widgets/panes/thumbnail_pane.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import 'fixtures/pdf_fixture.dart';

Future<void> waitForNative(
  WidgetTester tester,
  bool Function() complete,
) async {
  for (var attempt = 0; attempt < 150; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 20));
    if (complete()) return;
  }
  fail('The native reader did not reach the expected state.');
}

Future<void> captureReader(WidgetTester tester, String name) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('reader-capture')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/test-artifacts/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('reader searches, highlights, saves and closes a real PDF', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await (FontLoader('Urbanist')..addFont(
            rootBundle.load(
              'assets/fonts/Urbanist/static/Urbanist-Regular.ttf',
            ),
          ))
          .load();
      await (FontLoader('packages/font_awesome_flutter/FontAwesomeSolid')
            ..addFont(
              rootBundle.load(
                'packages/font_awesome_flutter/lib/fonts/Font-Awesome-7-Free-Solid-900.otf',
              ),
            ))
          .load();
    });
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final temporary = await tester.runAsync(
      () => Directory.systemTemp.createTemp('podofo-reader-'),
    );
    await tester.runAsync(() => pdfrxInitialize(tmpPath: temporary!.path));
    final file = File('${temporary!.path}/reader.pdf')
      ..writeAsBytesSync(pdfFixture());
    final store = Store(getObjectBoxModel(), directory: '${temporary.path}/db');
    store.box<DocumentEntity>().put(DocumentEntity(filePath: file.path));
    store.box<UserState>().put(UserState()..autoSaveEnabled = false);
    final container = ProviderContainer(
      overrides: [objectboxProvider.overrideWithValue(ObjectBox(store))],
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
      expect(tester.takeException(), isNull);
      final controller = container.read(pdfViewerControllerProvider);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // The scroll thumb follows the visible fraction, including zoom/resize,
      // and stays draggable at both ends instead of using a fixed height.
      final scrollThumb = find.byType(PdfViewerScrollThumb);
      double thumbHeight() =>
          tester.widget<PdfViewerScrollThumb>(scrollThumb).thumbSize!.height;
      final initialTransform = controller.value.clone();
      final initialZoom = controller.currentZoom;
      final initialThumbHeight = thumbHeight();
      expect(initialThumbHeight, greaterThan(40));
      await controller.setZoom(
        controller.centerPosition,
        initialZoom * 2,
        duration: Duration.zero,
      );
      await tester.pump();
      expect(thumbHeight(), closeTo(initialThumbHeight / 2, 0.5));

      tester.view.physicalSize = const Size(1200, 650);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(thumbHeight(), lessThan(initialThumbHeight / 2));
      await controller.setZoom(
        controller.centerPosition,
        controller.maxScale,
        duration: Duration.zero,
      );
      await tester.pump();
      expect(thumbHeight(), closeTo(40, 0.5));

      tester.view.physicalSize = const Size(1200, 900);
      await tester.pump();
      controller.value = initialTransform;
      await tester.pump(const Duration(milliseconds: 300));
      expect(thumbHeight(), closeTo(initialThumbHeight, 0.5));
      final thumbHandle = find.descendant(
        of: scrollThumb,
        matching: find.byType(GestureDetector),
      );
      final viewport = tester.getRect(find.byType(PdfViewer));
      await tester.dragFrom(
        tester.getCenter(thumbHandle),
        Offset(0, viewport.height * 2),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      expect(
        controller.visibleRect.bottom,
        closeTo(controller.documentSize.height, 1),
      );
      await tester.dragFrom(
        tester.getCenter(thumbHandle),
        Offset(0, -viewport.height * 2),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      expect(controller.visibleRect.top, closeTo(0, 1));
      controller.value = initialTransform;
      await tester.pump();
      // Mode toggles and the direct shortcut are harmless with no selection.
      await tester.tap(find.byKey(const ValueKey('highlight-mode')));
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        container.read(userStateNotifierProvider).highlightModeEnabled,
        true,
      );
      await tester.tap(find.byKey(const ValueKey('highlight-mode')));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(container.read(documentErrorProvider), isNull);
      expect(container.read(currentDocumentProvider)!.dirty, false);
      final searcher = container.read(pdfTextSearcherProvider)!;
      searcher.startTextSearch('Hello', searchImmediately: true);
      await waitForNative(
        tester,
        () => !searcher.isSearching && searcher.matches.length == 3,
      );
      expect(searcher.matches.map((m) => m.pageNumber), [1, 2, 3]);

      // The toolbar retains the compact, right-click palette and inline picker.
      await tester.tap(
        find.byKey(const ValueKey('highlight-mode')),
        buttons: kSecondaryMouseButton,
        kind: PointerDeviceKind.mouse,
      );
      await waitForNative(
        tester,
        () => find.byType(HighlightPalette).evaluate().isNotEmpty,
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(HighlightPalette), findsOneWidget);
      expect(find.text('Color 1'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('highlight-color-2')));
      await tester.pump();
      expect(
        container.read(userStateNotifierProvider).highlightActiveColorIndex,
        2,
      );
      await captureReader(tester, 'highlight-palette');
      await tester.tap(find.byKey(const ValueKey('highlight-custom-color')));
      await waitForNative(
        tester,
        () => find.byType(shadcn.ColorPicker).evaluate().isNotEmpty,
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(shadcn.ColorPicker), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      await tester.enterText(
        find
            .descendant(
              of: find.byType(shadcn.ColorPicker),
              matching: find.byType(EditableText),
            )
            .first,
        '#3366cc',
      );
      await tester.pump();
      expect(
        container.read(userStateNotifierProvider).highlightColor,
        '#663366cc',
      );
      expect(
        store.box<UserState>().getAll().single.highlightColor,
        '#663366cc',
      );
      await captureReader(tester, 'highlight-custom-picker');
      // Dismiss the nested picker and palette without changing the selection.
      await tester.tapAt(const Offset(10, 800));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tapAt(const Offset(10, 800));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(HighlightPalette), findsNothing);

      await tester.runAsync(
        () => controller.textSelectionDelegate.selectAllText(),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('highlight-mode')));
      await waitForNative(
        tester,
        () => find.textContaining('● reader').evaluate().isNotEmpty,
      );
      expect(container.read(currentDocumentProvider)!.dirty, true);
      expect(find.textContaining('● reader'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // Highlight mode waits for pointer release, including a paused drag.
      final pdf = container.read(currentDocumentProvider)!.pdfDocument;
      final text = await tester.runAsync(
        () => pdf.pages.first.loadStructuredText(),
      );
      final range = PdfTextSelectionRange.fromPoints(
        PdfTextSelectionPoint(text!, 0),
        PdfTextSelectionPoint(text, 4),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(PdfViewer)),
        kind: PointerDeviceKind.mouse,
      );
      await tester.runAsync(
        () =>
            controller.textSelectionDelegate.setTextSelectionPointRange(range),
      );
      final before = container.read(currentDocumentProvider)!.session.revision;
      await tester.pump(const Duration(milliseconds: 400));
      expect(container.read(currentDocumentProvider)!.session.revision, before);
      await gesture.up();
      await waitForNative(
        tester,
        () =>
            container.read(currentDocumentProvider)!.session.revision > before,
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        container.read(currentDocumentProvider)!.session.revision,
        before + 1,
      );
      await tester.tap(find.byKey(const ValueKey('highlight-mode')));
      await tester.pump();
      expect(
        container.read(userStateNotifierProvider).highlightModeEnabled,
        false,
      );

      // With mode off, a selection-menu swatch applies its own chosen color.
      await tester.runAsync(
        () =>
            controller.textSelectionDelegate.setTextSelectionPointRange(range),
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(
        find.byType(PdfViewer),
        buttons: kSecondaryMouseButton,
        kind: PointerDeviceKind.mouse,
      );
      await waitForNative(
        tester,
        () => find.byType(PdfSelectionMenu).evaluate().isNotEmpty,
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(PdfSelectionMenu), findsOneWidget);
      await captureReader(tester, 'highlight-selection-menu');
      await tester.tap(find.byKey(const ValueKey('highlight-color-3')));
      await waitForNative(
        tester,
        () =>
            container.read(currentDocumentProvider)!.session.revision >
            before + 1,
      );
      final highlights = await tester.runAsync(
        () => PdfHighlights.listPage(pdf, 1),
      );
      expect(highlights, hasLength(3));
      expect(
        container.read(userStateNotifierProvider).highlightActiveColorIndex,
        3,
      );
      expect(find.byType(PdfSelectionMenu), findsNothing);
      expect(container.read(documentErrorProvider), isNull);

      // Cancelling close must keep both the tab and its unsaved annotations.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyW);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(find.text('Save changes to reader.pdf?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(container.read(currentDocumentProvider)!.dirty, true);

      await tester.tap(find.byTooltip('Annotations'));
      await waitForNative(
        tester,
        () => find.byTooltip('Remove highlight').evaluate().isNotEmpty,
      );
      expect(find.textContaining('Hello highlight'), findsWidgets);
      await tester.tap(find.byTooltip('Thumbnails'));
      await waitForNative(
        tester,
        () =>
            tester
                .widgetList<RawImage>(
                  find.descendant(
                    of: find.byType(ThumbnailPane),
                    matching: find.byType(RawImage),
                  ),
                )
                .where((image) => image.image != null)
                .length ==
            3,
      );
      expect(find.text('Page 1'), findsNothing);
      final firstThumbnail = find.byKey(const ValueKey('thumbnail-1'));
      final cardSize = tester.getSize(firstThumbnail);
      final landscapeSize = tester.getSize(
        find.byKey(const ValueKey('thumbnail-2')),
      );
      expect(landscapeSize.width, cardSize.width);
      expect(landscapeSize.height, lessThan(cardSize.height));
      expect(find.byType(ThumbnailCard), findsNWidgets(3));
      await tester.pump(const Duration(milliseconds: 400));
      await captureReader(tester, 'thumbnails-light');

      // Restore focus-to-page navigation, including traversal between cards.
      final secondThumbnail = find.byKey(const ValueKey('thumbnail-2'));
      final secondButton = tester.widget<shadcn.Button>(
        find.descendant(
          of: secondThumbnail,
          matching: find.byType(shadcn.Button),
        ),
      );
      secondButton.focusNode!.requestFocus();
      await waitForNative(tester, () => controller.pageNumber == 2);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await waitForNative(tester, () => controller.pageNumber == 3);

      // A theme change must retain the thumbnail scroll position and PDF viewport.
      final thumbnailScrollable = tester.state<ScrollableState>(
        find.descendant(
          of: find.byType(ThumbnailPane),
          matching: find.byType(Scrollable),
        ),
      );
      final thumbnailOffset = thumbnailScrollable.position.pixels;
      final preferences = container.read(userPreferenceProvider.notifier);
      await tester.runAsync(
        () => preferences.setThemeMode(shadcn.ThemeMode.dark),
      );
      await tester.pump(const Duration(milliseconds: 400));
      if (ui.ImageFilter.isShaderFilterSupported) {
        await tester.runAsync(() => preferences.setShaderPreference(true));
        await waitForNative(
          tester,
          () => container.read(shaderProvider) != null,
        );
        expect(
          find.descendant(
            of: firstThumbnail,
            matching: find.byType(ImageFiltered),
          ),
          findsOneWidget,
        );
      }
      await captureReader(tester, 'thumbnails-dark');
      expect(thumbnailScrollable.position.pixels, thumbnailOffset);
      expect(controller.pageNumber, 3);
      await tester.runAsync(() => preferences.setShaderPreference(false));
      await tester.runAsync(
        () => preferences.setThemeMode(shadcn.ThemeMode.light),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('File'));
      await waitForNative(
        tester,
        () => find.text('Save').evaluate().isNotEmpty,
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Save').last);
      await waitForNative(
        tester,
        () => !container.read(currentDocumentProvider)!.dirty,
      );
      expect(container.read(documentErrorProvider), isNull);
      expect(find.textContaining('● reader'), findsNothing);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyW);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await waitForNative(
        tester,
        () => container.read(loadedDocumentsProvider).isEmpty,
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Press the plus icon to pick a PDF file.'),
        findsOneWidget,
      );
      expect(container.read(pdfTextSearcherProvider), isNull);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      store.close();
      await tester.runAsync(() async {
        await PdfrxEntryFunctions.instance.stopBackgroundWorker();
        await temporary.delete(recursive: true);
      });
    }
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
