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
import 'package:podofo_one/src/widgets/areas/title_bar.dart';
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

// Exercise Flutter's native menu serialization and inbound selection dispatch.
class _MenuChannel extends OptionalMethodChannel {
  _MenuChannel() : super('test/history-menu');
  Future<void> Function(MethodCall)? incoming;
  Map<dynamic, dynamic> menus = {};
  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async {
    if (method == 'Menu.setMenus') menus = arguments as Map;
    return null;
  }

  @override
  void setMethodCallHandler(Future<void> Function(MethodCall)? handler) {
    incoming = handler;
  }

  List<Map> get editItems => (menus['0'] as List)
      .cast<Map>()
      .firstWhere((menu) => menu['label'] == 'Edit')['children']
      .cast<Map>();
}

class _Menus {
  _Menus(this.tester, this.platform, this.channel);
  final WidgetTester tester;
  final TargetPlatform platform;
  final _MenuChannel channel;
  bool get native => platform == TargetPlatform.macOS;
  Future<void> check(
    String undo,
    bool canUndo,
    String redo,
    bool canRedo,
  ) async {
    await tester.pump();
    await tester.pump();
    if (native) {
      final items = channel.editItems;
      expect(items.map((i) => i['label']), [undo, redo]);
      expect(items.map((i) => i['enabled']), [canUndo, canRedo]);
      expect(items.map((i) => i['shortcutModifiers']), [
        1,
        3,
      ]); // Cmd / Cmd+Shift
    } else {
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      final items = tester
          .widgetList<PopupMenuItem<VoidCallback>>(
            find.byType(PopupMenuItem<VoidCallback>),
          )
          .toList();
      expect(items.map((i) => (i.child as Text).data), [undo, redo]);
      expect(items.map((i) => i.enabled), [canUndo, canRedo]);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
    }
  }

  Future<void> select(String label) async {
    if (native) {
      final item = channel.editItems.firstWhere((i) => i['label'] == label);
      expect(item['enabled'], true);
      await channel.incoming!(MethodCall('Menu.selectedCallback', item['id']));
    } else {
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
    }
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }
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

    testWidgets(
      'Edit menu labels, saved state, branching and active tab stay in sync',
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
        final channel = _MenuChannel();
        final originalDelegate = WidgetsBinding.instance.platformMenuDelegate;
        WidgetsBinding.instance.platformMenuDelegate =
            DefaultPlatformMenuDelegate(channel: channel);
        final menu = _Menus(tester, platform, channel);
        final focus = FocusNode();
        try {
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: shadcn.ShadcnApp(
                localizationsDelegates: const [
                  DefaultMaterialLocalizations.delegate,
                ],
                home: Theme(
                  data: ThemeData(platform: platform),
                  child: Material(
                    child: AppShortcuts(
                      child: TitleBar(
                        child: Focus(
                          focusNode: focus,
                          child: const SizedBox.expand(),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          focus.requestFocus();
          await menu.check('Undo Add highlight', true, 'Redo', false);
          await tester.runAsync(first.session.save);
          notifier.refresh();
          await menu.check('Undo Add highlight', true, 'Redo', false);
          await menu.select('Undo Add highlight');
          await idle(tester, first.session);
          expect(first.dirty, true); // undo before the saved state
          await menu.check('Undo', false, 'Redo Add highlight', true);
          await key(tester, redo: true);
          await idle(tester, first.session);
          expect(first.dirty, false);
          await menu.check('Undo Add highlight', true, 'Redo', false);
          await key(tester);
          await idle(tester, first.session);
          await menu.check('Undo', false, 'Redo Add highlight', true);
          await tester.runAsync(
            () => notifier.highlight(first, [
              const HighlightRegion(1, [PdfRect(20, 120, 130, 100)]),
            ], 0x660000ff),
          );
          expect(first.dirty, true);
          await menu.check('Undo Add highlight', true, 'Redo', false);
          final firstRevision = first.session.revision;
          container.read(currentTabIndexProvider.notifier).state = 1;
          await menu.check('Undo Add highlight', true, 'Redo', false);
          await menu.select('Undo Add highlight');
          await idle(tester, second.session);
          expect(first.session.revision, firstRevision);
          expect(second.dirty, false);
          await menu.check('Undo', false, 'Redo Add highlight', true);
          await menu.select('Redo Add highlight');
          await idle(tester, second.session);
          expect(second.dirty, true);
          notifier.clear();
          await menu.check('Undo', false, 'Redo', false);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          WidgetsBinding.instance.platformMenuDelegate = originalDelegate;
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
        'Edit menu preserves text focus and empty history (shadcn: $customField)',
        (tester) async {
          final doc = (await tester.runAsync(document))!;
          final container = ProviderContainer(
            overrides: [
              loadedDocumentsProvider.overrideWith(() => _Documents([doc])),
              userStateNotifierProvider.overrideWith(_Preferences.new),
            ],
          );
          final channel = _MenuChannel();
          final originalDelegate = WidgetsBinding.instance.platformMenuDelegate;
          WidgetsBinding.instance.platformMenuDelegate =
              DefaultPlatformMenuDelegate(channel: channel);
          final menu = _Menus(tester, platform, channel);
          final text = TextEditingController(text: 'original');
          final undo = UndoHistoryController();
          final textFocus = FocusNode(), canvasFocus = FocusNode();
          try {
            final field = customField
                ? shadcn.TextField(
                    controller: text,
                    focusNode: textFocus,
                    undoController: undo,
                  )
                : TextField(
                    controller: text,
                    focusNode: textFocus,
                    undoController: undo,
                  );
            await tester.pumpWidget(
              UncontrolledProviderScope(
                container: container,
                child: shadcn.ShadcnApp(
                  localizationsDelegates: const [
                    DefaultMaterialLocalizations.delegate,
                  ],
                  home: Theme(
                    data: ThemeData(platform: platform),
                    child: Material(
                      child: AppShortcuts(
                        child: TitleBar(
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
              ),
            );
            textFocus.requestFocus();
            await tester.pump(const Duration(milliseconds: 600));
            await menu.check('Undo', false, 'Redo', false);
            await tester.enterText(find.byType(EditableText), 'edited');
            await tester.pump(const Duration(milliseconds: 600));
            await menu.check('Undo', true, 'Redo', false);
            await menu.select('Undo');
            expect(text.text, 'original');
            expect(doc.session.revision, 1);
            await menu.check('Undo', false, 'Redo', true);
            await menu.select('Redo');
            expect(text.text, 'edited');
            expect(doc.session.revision, 1);
            canvasFocus.requestFocus();
            await menu.check('Undo Add highlight', true, 'Redo', false);
            await menu.select('Undo Add highlight');
            await idle(tester, doc.session);
            expect(doc.dirty, false);
            expect(text.text, 'edited');
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox());
            WidgetsBinding.instance.platformMenuDelegate = originalDelegate;
            text.dispose();
            undo.dispose();
            textFocus.dispose();
            canvasFocus.dispose();
            container.dispose();
            await tester.runAsync(() => doc.session.close(discard: true));
          }
        },
        variant: TargetPlatformVariant.only(platform),
      );

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
