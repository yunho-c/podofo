import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:podofo_one/src/data/document_data.dart';
import 'package:podofo_one/src/editing/annotation_edit.dart';
import 'package:podofo_one/src/editing/pdf_annotation_adapter.dart';
import 'package:podofo_one/src/providers/document_provider.dart';
import 'package:podofo_one/src/providers/user_state_provider.dart';
import 'package:podofo_one/src/services/pdf_session.dart';
import 'package:podofo_one/src/widgets/components/highlight_palette.dart';
import 'package:podofo_one/src/widgets/components/pdf_selection_menu.dart';

import 'fixtures/annotation_pdf.dart';

class _DelayedAdapter extends PdfAnnotationAdapter {
  final gate = Completer<void>();
  bool fail = false;
  int scans = 0;
  @override
  Future<Map<String, AnnotationRecord>> initialize(PdfDocument pdf) async {
    scans++;
    await gate.future;
    if (fail) throw StateError('Test scan failure');
    return super.initialize(pdf);
  }
}

class _Selection implements PdfTextSelectionDelegate {
  @override
  bool get hasSelectedText => false;
  @override
  bool get isCopyAllowed => false;
  @override
  bool get isSelectingAllText => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Preferences extends UserStateNotifier {
  @override
  UserState build() => UserState()..highlightColorPalette = ['#66ffeb3b'];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final scenario in [
    'ready',
    'complete',
    'escape',
    'outside',
    'replace',
    'failure',
  ]) {
    testWidgets('annotation menu first frame: $scenario', (tester) async {
      final temp = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('podofo-menu-load-'),
      ))!;
      final file = File('${temp.path}/annotations.pdf')
        ..writeAsBytesSync(
          annotationPdf(relationships: false, firstName: 'PoDoFo:imported'),
        );
      final adapter = _DelayedAdapter();
      final session = (await tester.runAsync(() async {
        await pdfrxInitialize(tmpPath: temp.path);
        return PdfSession.open(file.path, annotationAdapter: adapter);
      }))!;
      final document = Document(session: session);
      final request = ValueNotifier(
        AnnotationMenuRequest(document, 1, const PdfPoint(60, 110)),
      );
      final visible = ValueNotifier(true);
      final releaseLock = Completer<void>();
      Future<void>? locked;
      try {
        expect(adapter.scans, 1, reason: 'Opening starts the scan');
        expect(session.annotationsReady, false);
        expect(() => session.annotationAt(1, 60, 110), throwsStateError);
        if (scenario == 'ready') {
          await tester.runAsync(() async {
            adapter.gate.complete();
            await session.prepareAnnotations();
            // The menu must not wait behind an in-flight save/read operation.
            locked = session.readLocked((_) => releaseLock.future);
          });
        }
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              currentDocumentProvider.overrideWith((ref) => document),
              userStateNotifierProvider.overrideWith(_Preferences.new),
            ],
            child: ShadcnApp(
              home: TapRegionSurface(
                child: Stack(
                  children: [
                    const Positioned.fill(
                      child: ColoredBox(color: Color(0xffffffff)),
                    ),
                    Positioned(
                      left: 50,
                      top: 50,
                      child: ValueListenableBuilder(
                        valueListenable: visible,
                        builder: (context, show, _) => show
                            ? ValueListenableBuilder(
                                valueListenable: request,
                                builder: (context, target, _) =>
                                    PdfSelectionMenu(
                                      params: PdfViewerContextMenuBuilderParams(
                                        isTextSelectionEnabled: true,
                                        anchorA: const Offset(50, 50),
                                        textSelectionDelegate: _Selection(),
                                        dismissContextMenu: () =>
                                            visible.value = false,
                                        contextMenuFor:
                                            PdfViewerPart.background,
                                      ),
                                      annotationRequest: target,
                                      onHighlight: (_) {},
                                      onUnderline: () {},
                                      twoPageView: false,
                                      onTwoPageViewChanged: (_) {},
                                    ),
                              )
                            : const SizedBox.shrink(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        expect(find.text('Loading annotation…'), findsNothing);
        if (scenario == 'ready') {
          // No extra pump or asynchronous completion before these assertions.
          expect(find.text('Remove highlight'), findsOneWidget);
          expect(find.byType(HighlightPalette), findsOneWidget);
          request.value = AnnotationMenuRequest(
            document,
            1,
            const PdfPoint(350, 180),
          );
          await tester.pump();
          expect(find.text('Remove highlight'), findsNothing);
          expect(find.text('Select all'), findsOneWidget);
        } else {
          expect(find.byType(MenuPopup), findsNothing);
          await tester.pump(); // Install keyboard focus for dismissal.
          if (scenario == 'escape') {
            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          } else if (scenario == 'outside') {
            await tester.tapAt(const Offset(500, 400));
          } else if (scenario == 'replace') {
            request.value = AnnotationMenuRequest(
              document,
              1,
              const PdfPoint(350, 180),
            );
          }
          await tester.pump();
          adapter.fail = scenario == 'failure';
          await tester.runAsync(() async {
            adapter.gate.complete();
            try {
              await session.prepareAnnotations();
            } catch (_) {
              if (!adapter.fail) rethrow;
            }
          });
          await tester.pump();
          expect(find.text('Loading annotation…'), findsNothing);
          if (scenario == 'escape' || scenario == 'outside') {
            expect(visible.value, false);
            expect(find.byType(MenuPopup), findsNothing);
          } else if (scenario == 'failure') {
            expect(
              find.text('Annotation unavailable. Reopen menu.'),
              findsOneWidget,
            );
            expect(find.byType(HighlightPalette), findsNothing);
          } else {
            expect(find.text('Select all'), findsOneWidget);
            expect(
              find.text('Remove highlight'),
              scenario == 'complete' ? findsOneWidget : findsNothing,
            );
          }
        }
        expect(adapter.scans, 1);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        request.dispose();
        visible.dispose();
        await tester.runAsync(() async {
          if (!adapter.gate.isCompleted) adapter.gate.complete();
          if (!releaseLock.isCompleted) releaseLock.complete();
          await locked;
          await session.close(discard: true);
          await PdfrxEntryFunctions.instance.stopBackgroundWorker();
          await temp.delete(recursive: true);
        });
      }
    });
  }
}
