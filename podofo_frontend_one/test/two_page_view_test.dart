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
import 'package:podofo_one/src/providers/data_provider.dart';
import 'package:podofo_one/src/providers/document_provider.dart';
import 'package:podofo_one/src/providers/tab_provider.dart';
import 'package:podofo_one/src/widgets/components/pdf_selection_menu.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures/pdf_fixture.dart';

Future<void> _waitFor(WidgetTester tester, bool Function() complete) async {
  for (var i = 0; i < 150; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 20));
    if (complete()) return;
  }
  fail('Reader did not reach the expected state.');
}

Future<void> _openMenu(WidgetTester tester) async {
  await tester.pumpAndSettle();
  // The background outside the page must offer layout controls too.
  await tester.tapAt(
    tester.getTopLeft(find.byType(PdfViewer)) + const Offset(4, 4),
    buttons: kSecondaryMouseButton,
    kind: PointerDeviceKind.mouse,
  );
  await _waitFor(tester, () => find.text('Two pages').evaluate().isNotEmpty);
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _capture(WidgetTester tester, String name) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('two-page-capture')),
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

bool _checked(WidgetTester tester, String label) => find
    .descendant(
      of: find.ancestor(
        of: find.text(label),
        matching: find.byType(shadcn.MenuButton),
      ),
      matching: find.byIcon(shadcn.RadixIcons.check),
    )
    .evaluate()
    .isNotEmpty;

bool _fullyVisible(PdfViewerController controller, Rect rect) {
  final visible = controller.visibleRect.inflate(0.01);
  return visible.contains(rect.topLeft) && visible.contains(rect.bottomRight);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('right-click switches layouts, preserves selection and tab mode', (
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
      await (FontLoader('packages/shadcn_flutter/GeistSans')..addFont(
            rootBundle.load(
              'packages/shadcn_flutter/lib/fonts/Geist-Regular.otf',
            ),
          ))
          .load();
      await (FontLoader('packages/shadcn_flutter/RadixIcons')..addFont(
            rootBundle.load('packages/shadcn_flutter/lib/icons/RadixIcons.otf'),
          ))
          .load();
    });
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final temporary = await tester.runAsync(
      () => Directory.systemTemp.createTemp('podofo-two-page-'),
    );
    await tester.runAsync(() => pdfrxInitialize(tmpPath: temporary!.path));
    final file = File('${temporary!.path}/reader.pdf')
      ..writeAsBytesSync(pdfFixture());
    final other = File('${temporary.path}/other.pdf')
      ..writeAsBytesSync(pdfFixture(pageCount: 2));
    final store = Store(getObjectBoxModel(), directory: '${temporary.path}/db');
    store.box<DocumentEntity>().put(DocumentEntity(filePath: file.path));
    final container = ProviderContainer(
      overrides: [objectboxProvider.overrideWithValue(ObjectBox(store))],
    );
    try {
      await tester.pumpWidget(
        RepaintBoundary(
          key: const ValueKey('two-page-capture'),
          child: UncontrolledProviderScope(
            container: container,
            child: const MyApp(),
          ),
        ),
      );
      await _waitFor(
        tester,
        () => container.read(pdfTextSearcherProvider) != null,
      );
      final controller = container.read(pdfViewerControllerProvider);
      final session = container.read(currentDocumentProvider)!.session;
      await _openMenu(tester);
      expect(_checked(tester, 'Single page'), isTrue);
      expect(_checked(tester, 'Two pages'), isFalse);
      await tester.tap(find.text('Two pages'));
      await _waitFor(tester, () {
        final rects = controller.layout.pageLayouts;
        return rects[0].center.dy == rects[1].center.dy &&
            _fullyVisible(controller, rects[0].expandToInclude(rects[1]));
      });
      expect(find.byType(PdfSelectionMenu), findsNothing);
      expect(container.read(pdfViewerControllerProvider), same(controller));
      expect(container.read(currentDocumentProvider)!.session, same(session));
      expect(session.dirty, isFalse);
      await tester.pumpAndSettle();
      await _capture(tester, 'two-page-view');
      expect(
        controller.layout.pageLayouts[2].top,
        greaterThan(controller.layout.pageLayouts[0].bottom),
      );

      // Selection on the right page survives a layout change.
      final text = await tester.runAsync(
        () => session.lease.document.pages[1].loadStructuredText(),
      );
      await tester.runAsync(
        () => controller.textSelectionDelegate.setTextSelectionPointRange(
          PdfTextSelectionRange.fromPoints(
            PdfTextSelectionPoint(text!, 0),
            PdfTextSelectionPoint(text, 4),
          ),
        ),
      );
      await _openMenu(tester);
      expect(_checked(tester, 'Two pages'), isTrue);
      expect(find.text('Copy'), findsOneWidget);
      expect(find.text('Highlight'), findsOneWidget);
      await _capture(tester, 'two-page-context-menu');
      await tester.tap(find.text('Single page'));
      await _waitFor(tester, () => controller.params.layoutPages == null);
      expect(
        await tester.runAsync(
          () => controller.textSelectionDelegate.getSelectedText(),
        ),
        'Hello',
      );
      await tester.runAsync(
        () => controller.textSelectionDelegate.clearTextSelection(),
      );

      // Switching on the final, unpaired page keeps it in view.
      await controller.goToPage(pageNumber: 3, duration: Duration.zero);
      await tester.pump(const Duration(milliseconds: 300));
      await _openMenu(tester);
      await tester.tap(find.text('Two pages'));
      await _waitFor(
        tester,
        () =>
            controller.params.layoutPages != null &&
            _fullyVisible(controller, controller.layout.pageLayouts[2]),
      );
      expect(controller.pageNumber, 3);

      // Another tab starts in single-page mode; returning restores this spread.
      await tester.runAsync(
        () => container
            .read(loadedDocumentsProvider.notifier)
            .addDocument(other.path),
      );
      await _waitFor(
        tester,
        () =>
            container.read(currentDocumentProvider)?.title == 'other.pdf' &&
            container.read(pdfTextSearcherProvider) != null,
      );
      expect(container.read(currentDocumentProvider)!.twoPageView, isFalse);
      expect(
        container.read(pdfViewerControllerProvider).params.layoutPages,
        isNull,
      );
      // A document with just one spread must allow zooming out to fit both pages.
      await _openMenu(tester);
      await tester.tap(find.text('Two pages'));
      final otherController = container.read(pdfViewerControllerProvider);
      await _waitFor(tester, () {
        final rects = otherController.layout.pageLayouts;
        return otherController.params.layoutPages != null &&
            _fullyVisible(otherController, rects[0].expandToInclude(rects[1]));
      });
      container.read(currentTabIndexProvider.notifier).state = 0;
      await _waitFor(
        tester,
        () =>
            container.read(currentDocumentProvider)?.title == 'reader.pdf' &&
            container.read(pdfTextSearcherProvider) != null,
      );
      final restored = container.read(pdfViewerControllerProvider);
      await _waitFor(
        tester,
        () => _fullyVisible(restored, restored.layout.pageLayouts[2]),
      );
      expect(container.read(currentDocumentProvider)!.twoPageView, isTrue);
      await _openMenu(tester);
      expect(_checked(tester, 'Two pages'), isTrue);
      await tester.tap(find.text('Single page'));
      await _waitFor(
        tester,
        () =>
            restored.params.layoutPages == null &&
            _fullyVisible(restored, restored.layout.pageLayouts[2]),
      );
      expect(restored.pageNumber, 3);
      expect(session.dirty, isFalse);
      expect(container.read(documentErrorProvider), isNull);
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
