import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:mlsr/mlsr.dart' as mlsr;
import 'package:podoco/podoco.dart' as podoco;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:podofo_one/main.dart';
import 'package:podofo_one/objectbox.g.dart';
import 'package:podofo_one/src/analysis/analysis_controller.dart';
import 'package:podofo_one/src/analysis/analysis_store.dart';
import 'package:podofo_one/src/data/document_entity.dart';
import 'package:podofo_one/src/data/pane_data.dart';
import 'package:podofo_one/src/providers/ui_provider.dart';
import 'package:podofo_one/src/data/objectbox.dart';
import 'package:podofo_one/src/providers/analysis_provider.dart';
import 'package:podofo_one/src/providers/data_provider.dart';
import 'package:podofo_one/src/providers/document_provider.dart';
import 'package:podofo_one/src/providers/user_state_provider.dart';

import 'fixtures/pdf_fixture.dart';
import 'reader_widget_test.dart' show waitForNative, captureReader;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final bundle = Platform.environment['PODOCO_M2_BUNDLE'];
  testWidgets(
    'real analysis overlays repaint without replacing the reader document',
    (tester) async {
      await tester.runAsync(() async {
        for (final font in {
          'Urbanist': 'assets/fonts/Urbanist/static/Urbanist-Regular.ttf',
          // Supply Material's fallback alias in the font-isolated test runner.
          'Roboto': 'assets/fonts/Urbanist/static/Urbanist-Regular.ttf',
          'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
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
        () => Directory.systemTemp.createTemp('podoco-reader-'),
      ))!;
      await tester.runAsync(() => pdfrxInitialize(tmpPath: temporary.path));
      final file = File('${temporary.path}/reader.pdf')
        ..writeAsBytesSync(pdfFixture());
      final store = Store(
        getObjectBoxModel(),
        directory: '${temporary.path}/db',
      );
      store.box<DocumentEntity>().put(DocumentEntity(filePath: file.path));
      store.box<UserState>().put(UserState()..autoSaveEnabled = false);
      final analysis = AnalysisController(
        store: AnalysisStore(Directory('${temporary.path}/pages')),
      );
      final container = ProviderContainer(
        overrides: [
          objectboxProvider.overrideWithValue(ObjectBox(store)),
          analysisControllerProvider.overrideWith((ref) async {
            ref.listen(currentDocumentProvider, (_, document) {
              analysis.select(
                document?.session,
                (document?.lastOpenedPage ?? 1) - 1,
              );
            }, fireImmediately: true);
            return analysis;
          }),
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
        final viewer = container.read(pdfViewerControllerProvider);
        final document = container.read(currentDocumentProvider)!.pdfDocument;
        await tester.runAsync(() async {
          expect(mlsr.nativeVersion, isNotEmpty);
          await analysis.configure(bundle!);
          unawaited(analysis.analyze());
        });
        await waitForNative(tester, () => !analysis.running);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(analysis.error, isNull);
        expect(analysis.outcome?.status, podoco.CompletionStatus.completed);
        expect(analysis.visiblePage!.regions, isNotEmpty);
        expect(container.read(pdfViewerControllerProvider), same(viewer));
        expect(
          container.read(currentDocumentProvider)!.pdfDocument,
          same(document),
        );
        await captureReader(tester, 'podoco-layout-overlay');
        Future<int> bluePixels() async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('reader-capture')),
          );
          final image = await boundary.toImage();
          try {
            final data = await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            );
            final bytes = data!.buffer.asUint8List();
            var count = 0;
            for (var i = 0; i < bytes.length; i += 4) {
              if (bytes[i] < 80 &&
                  bytes[i + 1] > 100 &&
                  bytes[i + 1] < 180 &&
                  bytes[i + 2] > 170) {
                count++;
              }
            }
            return count;
          } finally {
            image.dispose();
          }
        }

        final shown = (await tester.runAsync(bluePixels))!;
        analysis.toggleRegions(false);
        await tester.pump();
        await tester.pump();
        final hidden = (await tester.runAsync(bluePixels))!;
        expect(shown, greaterThan(hidden + 50));
        analysis.toggleRegions(true);
        await viewer.goToPage(pageNumber: 2, duration: Duration.zero);
        await waitForNative(
          tester,
          () => analysis.visiblePage?.page.key.pageIndex == 1,
        );
        await tester.pump();
        await tester.pump();
        await captureReader(tester, 'podoco-layout-rotated');
        container
            .read(userStateNotifierProvider.notifier)
            .setDeveloperMode(true);
        container.read(rightPaneProvider.notifier).state = rightPaneData.items
            .firstWhere((item) => item.name == 'Debug');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Analyze document layout'), findsOneWidget);
        expect(find.text('Analysis completed'), findsOneWidget);
        expect(find.text('3 / 3 pages finished'), findsOneWidget);
        await captureReader(tester, 'podoco-layout-controls');

        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(analysis.close);
        analysis.dispose();
        container.dispose();
        store.close();
        await tester.runAsync(() async {
          await PdfrxEntryFunctions.instance.stopBackgroundWorker();
          await temporary.delete(recursive: true);
        });
      }
    },
    skip: bundle == null,
  );
}
