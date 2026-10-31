import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:podofo_one/src/data/document_data.dart';
import 'package:podofo_one/src/providers/document_provider.dart';
import 'package:podofo_one/src/providers/user_state_provider.dart';
import 'package:podofo_one/src/services/pdf_session.dart';
import 'package:podofo_one/src/widgets/components/pdf_page_layout.dart';
import 'package:podofo_one/src/widgets/panes/debug_pane.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'fixtures/pdf_fixture.dart';
import 'fixtures/spaced_text_pdf.dart';

class _UserState extends UserStateNotifier {
  @override
  UserState build() => UserState();
}

void main() {
  testWidgets('debug rendering status handles no open document', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [userStateNotifierProvider.overrideWith(_UserState.new)],
        child: const ShadcnApp(home: SizedBox(width: 250, child: DebugPane())),
      ),
    );
    expect(find.text('Reduced-DPI cache'), findsOneWidget);
    expect(find.text('No document loaded'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sidebar follows actual preview and completed viewport renders', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(2000, 1200);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final temporary = Directory.systemTemp.createTempSync(
      'podofo-render-status-',
    );
    final file = File('${temporary.path}/page.pdf')
      ..writeAsBytesSync(spacedTextPdf());
    final spreadFile = File('${temporary.path}/spread.pdf')
      ..writeAsBytesSync(pdfFixture(pageCount: 2));
    final sessions = (await tester.runAsync(() async {
      await pdfrxInitialize(tmpPath: temporary.path);
      return [
        await PdfSession.open(file.path),
        await PdfSession.open(spreadFile.path),
      ];
    }))!;
    final controller = PdfViewerController();
    var document = Document(session: sessions.first);
    final container = ProviderContainer(
      overrides: [
        userStateNotifierProvider.overrideWith(_UserState.new),
        currentDocumentProvider.overrideWith((ref) => document),
        pdfViewerControllerProvider.overrideWithValue(controller),
      ],
    );

    Future<void> mount({bool spread = false}) => tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: ShadcnApp(
          home: Row(
            children: [
              Expanded(
                child: PdfViewer(
                  document.session.lease.reference,
                  controller: controller,
                  params: PdfViewerParams(
                    layoutPages: spread ? layoutTwoPages : null,
                    // Keep the pending-render state deterministic in this test.
                    behaviorControlParams: const PdfViewerBehaviorControlParams(
                      partialImageLoadingDelay: Duration(milliseconds: 200),
                    ),
                    sizeDelegateProvider: PdfViewerSizeDelegateProviderLegacy(
                      useAlternativeFitScaleAsMinScale: false,
                      calculateInitialZoom: (_, _, _, _) => 1,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 250, child: DebugPane()),
            ],
          ),
        ),
      ),
    );

    Future<void> zoom(double value) async {
      await controller.setZoom(
        controller.centerPosition,
        value,
        duration: Duration.zero,
      );
      await tester.pump();
      await tester.pump();
    }

    bool isMode(PdfPageRenderMode mode) =>
        controller.renderingStatus.value.singleOrNull?.mode == mode;

    try {
      await mount();
      await _waitFor(tester, () => isMode(PdfPageRenderMode.preview));
      expect(find.text('Page 1: Active'), findsOneWidget);
      expect(find.text('200 DPI cache · 144 DPI target'), findsOneWidget);

      // Equality stays on the preview path; only strictly greater switches.
      await zoom((200 / 72) / 2);
      expect(isMode(PdfPageRenderMode.preview), isTrue);
      await zoom(1.5);
      expect(isMode(PdfPageRenderMode.refining), isTrue);
      expect(find.text('Page 1: Refining…'), findsOneWidget);
      final matrix = controller.value.clone();
      await _waitFor(tester, () => isMode(PdfPageRenderMode.fullResolution));
      expect(controller.value, matrix);
      expect(find.text('Page 1: Inactive'), findsOneWidget);
      expect(find.text('200 DPI cache · 216 DPI target'), findsOneWidget);

      // Moving to a 1x display changes the path without changing zoom.
      tester.view.devicePixelRatio = 1;
      await _waitFor(tester, () => isMode(PdfPageRenderMode.preview));
      expect(find.text('200 DPI cache · 108 DPI target'), findsOneWidget);
      await zoom(3);
      // 3x on a 1x display reuses the completed 1.5x/2x bitmap immediately.
      expect(isMode(PdfPageRenderMode.fullResolution), isTrue);
      await _waitFor(tester, () => isMode(PdfPageRenderMode.fullResolution));

      // Reuse the controller for another document, including a visible spread.
      document = Document(session: sessions.last, twoPageView: true);
      container.invalidate(currentDocumentProvider);
      await mount(spread: true);
      await _waitFor(tester, () {
        final pages = controller.renderingStatus.value;
        return pages.length == 2 &&
            pages.every((p) => p.mode == PdfPageRenderMode.preview);
      });
      expect(find.text('Page 1: Active'), findsOneWidget);
      expect(find.text('Page 2: Active'), findsOneWidget);
      controller.value = controller.calcMatrixFor(
        controller.layout.pageLayouts.first.center,
        zoom: 8,
      );
      await _waitFor(
        tester,
        () =>
            controller.renderingStatus.value.length == 1 &&
            controller.renderingStatus.value.single.pageNumber == 1,
      );
      expect(find.textContaining('Page 2:'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(controller.renderingStatus.value, isEmpty);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      await tester.runAsync(() async {
        for (final session in sessions) {
          await session.close(discard: true);
        }
        await PdfrxEntryFunctions.instance.stopBackgroundWorker();
      });
      temporary.deleteSync(recursive: true);
    }
  });
}

Future<void> _waitFor(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 150; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump();
    if (ready()) return;
  }
  fail('Rendering status did not reach the expected state.');
}
