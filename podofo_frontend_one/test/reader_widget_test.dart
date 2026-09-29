import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'package:podofo_one/src/workers/thumbnail_worker.dart';

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('reader searches, highlights, saves and closes a real PDF', (
    tester,
  ) async {
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
        UncontrolledProviderScope(container: container, child: const MyApp()),
      );
      await waitForNative(
        tester,
        () => container.read(pdfTextSearcherProvider) != null,
      );
      expect(tester.takeException(), isNull);
      final controller = container.read(pdfViewerControllerProvider);
      final searcher = container.read(pdfTextSearcherProvider)!;
      searcher.startTextSearch('Hello', searchImmediately: true);
      await waitForNative(
        tester,
        () => !searcher.isSearching && searcher.matches.length == 3,
      );
      expect(searcher.matches.map((m) => m.pageNumber), [1, 2, 3]);

      await tester.runAsync(
        () => controller.textSelectionDelegate.selectAllText(),
      );
      await tester.pump();
      await tester.tap(find.byTooltip('Highlight selected text'));
      await waitForNative(
        tester,
        () => find.textContaining('● reader').evaluate().isNotEmpty,
      );
      expect(container.read(currentDocumentProvider)!.dirty, true);
      expect(find.textContaining('● reader'), findsOneWidget);
      expect(tester.takeException(), isNull);

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
        () => container.read(thumbnailCacheProvider).length == 3,
      );
      expect(find.text('Page 1'), findsOneWidget);
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
        find.text('Press the folder icon to pick a PDF file.'),
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
  });
}
