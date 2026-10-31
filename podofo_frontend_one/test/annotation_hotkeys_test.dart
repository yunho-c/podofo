import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:podofo_one/main.dart';
import 'package:podofo_one/objectbox.g.dart';
import 'package:podofo_one/src/data/document_data.dart';
import 'package:podofo_one/src/data/document_entity.dart';
import 'package:podofo_one/src/data/objectbox.dart';
import 'package:podofo_one/src/editing/annotation_edit.dart';
import 'package:podofo_one/src/narration/narration_controller.dart';
import 'package:podofo_one/src/providers/data_provider.dart';
import 'package:podofo_one/src/providers/document_provider.dart';
import 'package:podofo_one/src/providers/narration_provider.dart';
import 'package:podofo_one/src/providers/ui_provider.dart';
import 'package:podofo_one/src/providers/user_state_provider.dart';
import 'package:podofo_one/src/services/pdf_session.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures/spaced_text_pdf.dart';
import 'reader_widget_test.dart' show waitForNative;
import 'support/fake_narrator.dart';

const _firstColor = '#6633aa77';
const _activeColor = '#66aa33bb';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporary;
  var serial = 0;
  setUpAll(() async {
    temporary = await Directory.systemTemp.createTemp('podofo-hotkeys-');
    await pdfrxInitialize(tmpPath: temporary.path);
  });
  tearDownAll(() async {
    await PdfrxEntryFunctions.instance.stopBackgroundWorker();
    await temporary.delete(recursive: true);
  });

  Future<void> withReader(
    WidgetTester tester,
    Future<void> Function(ProviderContainer, Document) body,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final directory = Directory('${temporary.path}/${serial++}')..createSync();
    final file = File('${directory.path}/reader.pdf')
      ..writeAsBytesSync(spacedTextPdf());
    final store = Store(getObjectBoxModel(), directory: '${directory.path}/db');
    store.box<DocumentEntity>().put(DocumentEntity(filePath: file.path));
    store.box<UserState>().put(
      UserState()
        ..autoSaveEnabled = false
        ..highlightColorPalette = [_firstColor, _activeColor]
        ..highlightActiveColorIndex = 1
        ..highlightColor = _activeColor,
    );
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
        UncontrolledProviderScope(container: container, child: const MyApp()),
      );
      await waitForNative(
        tester,
        () => container.read(pdfTextSearcherProvider) != null,
      );
      final document = container.read(currentDocumentProvider)!;
      await waitForNative(tester, () => document.session.annotationsReady);
      await body(container, document);
      expect(container.read(documentErrorProvider), isNull);
      expect(tester.takeException(), isNull);
    } finally {
      final sessions = container
          .read(loadedDocumentsProvider)
          .values
          .map((document) => document.session)
          .toList();
      await tester.pumpWidget(const SizedBox());
      container.dispose();
      await tester.runAsync(() async {
        for (final session in sessions) {
          await session.close(discard: true);
        }
        narration.dispose();
      });
      store.close();
      // Let pdfrx's trailing-page delay observe that the viewer was disposed.
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  Future<void> select(WidgetTester tester, ProviderContainer container) async {
    final document = container.read(currentDocumentProvider)!;
    final viewer = container.read(pdfViewerControllerProvider);
    final text = (await tester.runAsync(
      () => document.pdfDocument.pages.first.loadStructuredText(),
    ))!;
    await tester.runAsync(
      () => viewer.textSelectionDelegate.setTextSelectionPointRange(
        PdfTextSelectionRange.fromPoints(
          PdfTextSelectionPoint(text, 0),
          PdfTextSelectionPoint(text, text.fullText.length - 1),
        ),
      ),
    );
    viewer.requestFocus();
    await tester.pump();
    expect(viewer.focusNode?.hasPrimaryFocus, true);
    expect(viewer.textSelectionDelegate.hasSelectedText, true);
  }

  for (final platform in [
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.linux,
  ]) {
    final command = platform == TargetPlatform.macOS
        ? LogicalKeyboardKey.metaLeft
        : LogicalKeyboardKey.controlLeft;
    Future<void> chord(
      WidgetTester tester,
      LogicalKeyboardKey key, {
      bool shift = false,
    }) async {
      await tester.sendKeyDownEvent(command);
      if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(key);
      if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(command);
      await tester.pump();
    }

    testWidgets(
      'h/u create markup immediately, preserve colors, and undo on $platform',
      (tester) async {
        await withReader(tester, (container, document) async {
          final session = document.session;
          final viewer = container.read(pdfViewerControllerProvider);
          viewer.requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
          await tester.sendKeyEvent(LogicalKeyboardKey.keyU);
          await tester.pump();
          expect(session.revision, 0);
          expect(
            container.read(userStateNotifierProvider).highlightModeEnabled,
            false,
          );

          await select(tester, container);
          await tester.sendKeyDownEvent(LogicalKeyboardKey.keyH);
          await waitForNative(tester, () => session.revision == 1);
          final highlight = (await tester.runAsync(session.annotations))!
              .single;
          expect(highlight.kind, AnnotationKind.highlight);
          expect(highlight.argb, 0x6633aa77);
          expect(session.undoLabel, 'Add highlight');
          expect(viewer.textSelectionDelegate.hasSelectedText, false);
          expect(
            container.read(userStateNotifierProvider).highlightColor,
            _activeColor,
          );
          expect(
            container.read(userStateNotifierProvider).highlightActiveColorIndex,
            1,
          );

          // A held h must not annotate a new selection made while it is down.
          await select(tester, container);
          await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyH);
          await tester.pump();
          expect(session.revision, 1);
          expect(viewer.textSelectionDelegate.hasSelectedText, true);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.keyH);

          await tester.sendKeyDownEvent(LogicalKeyboardKey.keyU);
          await waitForNative(tester, () => session.revision == 2);
          final annotations = (await tester.runAsync(session.annotations))!;
          final underline = annotations.singleWhere(
            (a) => a.kind == AnnotationKind.underline,
          );
          expect(underline.argb, AnnotationRecord.underlineColor);
          expect(annotations, hasLength(2));
          expect(session.undoLabel, 'Add underline');
          await select(tester, container);
          await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyU);
          await tester.pump();
          expect(session.revision, 2);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.keyU);

          await chord(tester, LogicalKeyboardKey.keyZ);
          await waitForNative(tester, () => session.revision == 3);
          expect(
            (await tester.runAsync(session.annotations))!.single.id,
            highlight.id,
          );
          await chord(tester, LogicalKeyboardKey.keyZ, shift: true);
          await waitForNative(tester, () => session.revision == 4);
          expect((await tester.runAsync(session.annotations))!, hasLength(2));

          // Existing modified shortcut still uses the active toolbar color.
          await select(tester, container);
          await chord(tester, LogicalKeyboardKey.keyH, shift: true);
          await waitForNative(tester, () => session.revision == 5);
          expect(
            (await tester.runAsync(session.annotations))!
                .where((a) => a.argb == 0x66aa33bb),
            hasLength(1),
          );
          await tester.runAsync(session.save);
          final reopened = (await tester.runAsync(
            () => PdfSession.open(document.filePath),
          ))!;
          try {
            expect(
              (await tester.runAsync(reopened.annotations))!,
              hasLength(3),
            );
          } finally {
            await tester.runAsync(() => reopened.close(discard: true));
          }
        });
      },
      variant: TargetPlatformVariant.only(platform),
    );

    testWidgets(
      'h/u respect modifiers, text fields, dialogs and the active tab on $platform',
      (tester) async {
        await withReader(tester, (container, document) async {
          final session = document.session;
          await select(tester, container);
          for (final modifier in [
            LogicalKeyboardKey.shiftLeft,
            LogicalKeyboardKey.controlLeft,
            LogicalKeyboardKey.metaLeft,
            LogicalKeyboardKey.altLeft,
          ]) {
            await tester.sendKeyDownEvent(modifier);
            await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
            await tester.sendKeyEvent(LogicalKeyboardKey.keyU);
            await tester.sendKeyUpEvent(modifier);
          }
          await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
          await tester.pump();
          expect(session.revision, 0);

          Future<void> typing() async {
            await tester.pumpAndSettle();
            final field = find.byType(EditableText).last;
            await tester.tap(field);
            await tester.pump();
            expect(
              container
                  .read(pdfViewerControllerProvider)
                  .focusNode
                  ?.hasPrimaryFocus,
              false,
            );
            expect(
              await tester.sendKeyDownEvent(LogicalKeyboardKey.keyH),
              false,
            );
            await tester.sendKeyUpEvent(LogicalKeyboardKey.keyH);
            expect(
              await tester.sendKeyDownEvent(LogicalKeyboardKey.keyU),
              false,
            );
            await tester.sendKeyUpEvent(LogicalKeyboardKey.keyU);
            await tester.enterText(field, 'hu');
            await tester.pump();
            expect(tester.widget<EditableText>(field).controller.text, 'hu');
            expect(session.revision, 0);
          }

          await chord(tester, LogicalKeyboardKey.keyF);
          await typing();
          // The selection remains available while a search field has focus.
          expect(
            container
                .read(pdfViewerControllerProvider)
                .textSelectionDelegate
                .hasSelectedText,
            true,
          );
          await select(tester, container);
          await chord(tester, LogicalKeyboardKey.keyP);
          await tester.pumpAndSettle();
          await typing();
          container.read(commandPaletteProvider.notifier).state = false;
          await tester.pump();

          await select(tester, container);
          final context = tester.element(find.byType(PdfViewer));
          final dialog = showDialog<void>(
            context: context,
            builder: (_) =>
                const AlertDialog(content: TextField(autofocus: true)),
          );
          await tester.pumpAndSettle();
          await typing();
          Navigator.of(context, rootNavigator: true).pop();
          await dialog;
          await tester.pumpAndSettle();

          final secondFile = File(
            '${File(document.filePath).parent.path}/second.pdf',
          )..writeAsBytesSync(spacedTextPdf());
          await tester.runAsync(
            () => container
                .read(loadedDocumentsProvider.notifier)
                .addDocument(secondFile.path),
          );
          await waitForNative(
            tester,
            () => container.read(pdfTextSearcherProvider) != null,
          );
          final second = container.read(currentDocumentProvider)!;
          expect(second.session, isNot(same(session)));
          await select(tester, container);
          await tester.sendKeyEvent(LogicalKeyboardKey.keyU);
          await waitForNative(tester, () => second.session.revision == 1);
          expect(session.revision, 0);
          expect(
            (await tester.runAsync(second.session.annotations))!.single.kind,
            AnnotationKind.underline,
          );
        });
      },
      variant: TargetPlatformVariant.only(platform),
    );
  }
}
