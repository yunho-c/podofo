import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:podofo_one/src/data/document_data.dart';
import 'package:podofo_one/src/providers/document_provider.dart';
import 'package:podofo_one/src/providers/hotkey_provider.dart';
import 'package:podofo_one/src/providers/tab_provider.dart';
import 'package:podofo_one/src/providers/user_state_provider.dart';
import 'package:podofo_one/src/services/pdf_highlights.dart';
import 'package:podofo_one/src/services/pdf_session.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import 'fixtures/spaced_text_pdf.dart';

Future<void> idle(WidgetTester tester, PdfSession session) async {
  var complete = false;
  final waiting = session.waitForIdle().then((_) => complete = true);
  for (var i = 0; i < 150 && !complete; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(complete, true, reason: 'The keyboard edit must finish.');
  await waiting;
}

// Only replace persistence/bootstrap; exercise the real notifier, session,
// worker, history, provider refresh, and Flutter keyboard dispatch.
class _Documents extends LoadedDocumentsNotifier {
  _Documents(this.documents);
  final List<Document> documents;
  @override
  Map<String, Document> build() => {
    for (final document in documents) document.filePath: document,
  };
  void clear() => state = {};
}

class _Preferences extends UserStateNotifier {
  @override
  UserState build() => UserState()..autoSaveEnabled = false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporary;
  var serial = 0;
  setUpAll(() async {
    temporary = await Directory.systemTemp.createTemp('podofo-shortcuts-');
    await pdfrxInitialize(tmpPath: temporary.path);
  });
  tearDownAll(() async {
    await PdfrxEntryFunctions.instance.stopBackgroundWorker();
    await temporary.delete(recursive: true);
  });
  Future<Document> document() async {
    final file = File('${temporary.path}/${serial++}.pdf');
    await file.writeAsBytes(spacedTextPdf());
    final session = await PdfSession.open(file.path);
    await session.highlight([
      const HighlightRegion(1, [PdfRect(20, 120, 130, 100)]),
    ], 0x66ffff00);
    return Document(session: session);
  }

  for (final platform in [
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.linux,
  ]) {
    Future<void> key(
      WidgetTester tester, {
      bool redo = false,
      bool y = false,
    }) async {
      final modifier = platform == TargetPlatform.macOS
          ? LogicalKeyboardKey.metaLeft
          : LogicalKeyboardKey.controlLeft;
      await tester.sendKeyDownEvent(modifier);
      if (redo && !y) {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      }
      await tester.sendKeyEvent(
        y ? LogicalKeyboardKey.keyY : LogicalKeyboardKey.keyZ,
      );
      if (redo && !y) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(modifier);
      await tester.pump();
    }

    testWidgets(
      'document shortcuts target the active tab and tolerate empty history',
      (tester) async {
        final first = (await tester.runAsync(document))!;
        final second = (await tester.runAsync(document))!;
        final notifier = _Documents([first, second]);
        final container = ProviderContainer(
          overrides: [
            loadedDocumentsProvider.overrideWith(() => notifier),
            userStateNotifierProvider.overrideWith(_Preferences.new),
          ],
        );
        final focus = FocusNode();
        Future<void> settle() async {
          await idle(tester, first.session);
          await idle(tester, second.session);
          await tester.pump();
        }

        try {
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: MaterialApp(
                home: AppShortcuts(
                  child: Focus(
                    focusNode: focus,
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
            ),
          );
          focus.requestFocus();
          await tester.pump();
          await key(tester);
          await settle();
          expect(first.session.canRedo, true);
          expect(first.dirty, false);
          expect(second.dirty, true);
          expect(container.read(currentDocumentProvider)!.dirty, false);
          await key(tester, redo: true);
          await settle();
          expect(first.dirty, true);
          final revision = first.session.revision;
          container.read(currentTabIndexProvider.notifier).state = 1;
          await tester.pump();
          await key(tester);
          await settle();
          expect(second.dirty, false);
          expect(first.session.revision, revision);
          final undoneRevision = second.session.revision;
          await key(tester); // no further undo
          await settle();
          expect(second.session.revision, undoneRevision);
          await key(tester, redo: true, y: platform != TargetPlatform.macOS);
          await settle();
          expect(second.dirty, true);
          await key(tester, redo: true); // no further redo
          await settle();
          expect(second.session.revision, undoneRevision + 1);
          notifier.clear();
          await tester.pump();
          await key(tester);
          await key(tester, redo: true);
          expect(container.read(documentErrorProvider), isNull);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          focus.dispose();
          container.dispose();
          await tester.runAsync(() async {
            await first.session.close(discard: true);
            await second.session.close(discard: true);
          });
        }
      },
      variant: TargetPlatformVariant.only(platform),
    );

    for (final customField in [false, true]) {
      testWidgets(
        'text undo stays local (shadcn: $customField), then returns to the PDF',
        (tester) async {
          final doc = (await tester.runAsync(document))!;
          final container = ProviderContainer(
            overrides: [
              loadedDocumentsProvider.overrideWith(() => _Documents([doc])),
              userStateNotifierProvider.overrideWith(_Preferences.new),
            ],
          );
          final canvasFocus = FocusNode();
          final textFocus = FocusNode();
          final text = TextEditingController(text: 'original');
          final originalRevision = doc.session.revision;
          try {
            final field = customField
                ? shadcn.TextField(controller: text, focusNode: textFocus)
                : TextField(controller: text, focusNode: textFocus);
            await tester.pumpWidget(
              UncontrolledProviderScope(
                container: container,
                child: shadcn.ShadcnApp(
                  theme: shadcn.ThemeData(
                    colorScheme: shadcn.ColorSchemes.lightZinc,
                  ),
                  localizationsDelegates: const [
                    DefaultMaterialLocalizations.delegate,
                  ],
                  home: Theme(
                    data: ThemeData(platform: platform),
                    child: Material(
                      child: AppShortcuts(
                        child: Column(
                          children: [
                            field,
                            Focus(
                              focusNode: canvasFocus,
                              child: const SizedBox(height: 100),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
            textFocus.requestFocus();
            await tester.pump(const Duration(milliseconds: 600));
            await key(tester); // empty text history must not undo the PDF
            expect(doc.session.revision, originalRevision);
            await tester.enterText(find.byType(EditableText), 'edited');
            await tester.pump(const Duration(milliseconds: 600));
            await key(tester);
            expect(text.text, 'original');
            await key(tester, redo: true);
            expect(text.text, 'edited');
            expect(doc.session.revision, originalRevision);
            if (platform != TargetPlatform.macOS) {
              await key(tester);
              await key(tester, redo: true, y: true);
              expect(text.text, 'edited');
            }
            canvasFocus.requestFocus();
            await tester.pump();
            await key(tester);
            await idle(tester, doc.session);
            await tester.pump();
            expect(doc.dirty, false);
            expect(text.text, 'edited');
            expect(container.read(documentErrorProvider), isNull);
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox());
            canvasFocus.dispose();
            textFocus.dispose();
            text.dispose();
            container.dispose();
            await tester.runAsync(() => doc.session.close(discard: true));
          }
        },
        variant: TargetPlatformVariant.only(platform),
      );
    }
  }
}
