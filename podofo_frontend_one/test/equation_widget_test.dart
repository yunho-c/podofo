import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:podoco/podoco.dart' as podoco;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:podofo_one/main.dart';
import 'package:podofo_one/objectbox.g.dart';
import 'package:podofo_one/src/analysis/analysis_controller.dart';
import 'package:podofo_one/src/analysis/analysis_store.dart';
import 'package:podofo_one/src/data/document_entity.dart';
import 'package:podofo_one/src/data/objectbox.dart';
import 'package:podofo_one/src/data/pane_data.dart';
import 'package:podofo_one/src/providers/analysis_provider.dart';
import 'package:podofo_one/src/providers/data_provider.dart';
import 'package:podofo_one/src/providers/document_provider.dart';
import 'package:podofo_one/src/providers/ui_provider.dart';
import 'package:podofo_one/src/providers/user_state_provider.dart';

import 'reader_widget_test.dart' show waitForNative, captureReader;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final layout = Platform.environment['PODOCO_M2_BUNDLE'];
  final formula = Platform.environment['PODOCO_M6_BUNDLE'];
  final rules = Platform.environment['PODOCO_M7_RULES'];
  final pdf = Platform.environment['PODOCO_M8_PDF'];
  testWidgets(
    'real formula controls and whole-equation overlay preserve reader identity',
    (tester) async {
      await tester.runAsync(() async {
        for (final font in {
          'Urbanist': 'assets/fonts/Urbanist/static/Urbanist-Regular.ttf',
          'Roboto': 'assets/fonts/Urbanist/static/Urbanist-Regular.ttf',
          'monospace': 'assets/fonts/Urbanist/static/Urbanist-Regular.ttf',
          'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
          'packages/font_awesome_flutter/FontAwesomeSolid': 'packages/font_awesome_flutter/lib/fonts/Font-Awesome-7-Free-Solid-900.otf',
        }.entries) {
          await (FontLoader(
            font.key,
          )..addFont(rootBundle.load(font.value))).load();
        }
      });
      SharedPreferences.setMockInitialValues({});
      String? clipboard;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              clipboard = (call.arguments as Map)['text'] as String;
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
      tester.view.physicalSize = const Size(1400, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final temporary = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('podoco-equation-reader-'),
      ))!;
      await tester.runAsync(() => pdfrxInitialize(tmpPath: temporary.path));
      final file = await tester.runAsync(
        () => File(pdf!).copy('${temporary.path}/page.pdf'),
      );
      final store = Store(
        getObjectBoxModel(),
        directory: '${temporary.path}/db',
      );
      store.box<DocumentEntity>().put(DocumentEntity(filePath: file!.path));
      store.box<UserState>().put(UserState()..autoSaveEnabled = false);
      final analysis = AnalysisController(
        store: AnalysisStore(Directory('${temporary.path}/pages')),
      );
      final container = ProviderContainer(
        overrides: [
          objectboxProvider.overrideWithValue(ObjectBox(store)),
          analysisControllerProvider.overrideWith((ref) async {
            ref.listen(
              currentDocumentProvider,
              (_, document) => analysis.select(
                document?.session,
                (document?.lastOpenedPage ?? 1) - 1,
              ),
              fireImmediately: true,
            );
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
          await analysis.configure(layout!, formulaDirectory: formula!);
          unawaited(analysis.analyze());
        });
        // Pump the app's pending cache restore as native jobs deliver updates.
        for (var i = 0; i < 1500 && analysis.running; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(analysis.running, false);
        await tester.pump();
        expect(analysis.error, isNull);
        expect(analysis.outcome!.status, podoco.CompletionStatus.completed);
        expect(analysis.visiblePage!.formulas, hasLength(8));
        final equations = container.read(equationControllerProvider)!;
        await tester.runAsync(() => equations.configureRules(rules!));
        expect(equations.error, isNull);
        container
            .read(userStateNotifierProvider.notifier)
            .setDeveloperMode(true);
        container.read(rightPaneProvider.notifier).state = rightPaneData.items
            .firstWhere((item) => item.name == 'Debug');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Analyze document and equations'), findsOneWidget);
        await tester.ensureVisible(find.text('Equation 1 · ready'));
        await tester.tap(find.text('Equation 1 · ready'));
        await tester.pump();
        await tester.pump();
        expect(
          equations.selected!.region.id,
          analysis.visiblePage!.formulas.first.regionId,
        );
        final originalLatex = equations.selected!.recognized!.latex;
        analysis.toggleRegions(false);
        await tester.pump();
        await tester.pump();
        await captureReader(tester, 'podoco-equation-selected');
        await tester.ensureVisible(find.text('Copy LaTeX'));
        await tester.tap(find.text('Copy LaTeX'));
        await tester.pump();
        expect(clipboard, originalLatex);
        await tester.ensureVisible(find.text('Listen to equation'));
        await tester.pump();
        await captureReader(tester, 'podoco-equation-controls');
        expect(container.read(pdfViewerControllerProvider), same(viewer));
        expect(
          container.read(currentDocumentProvider)!.pdfDocument,
          same(document),
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          await container.read(equationControllerProvider)?.close();
          await analysis.close();
        });
        analysis.dispose();
        container.dispose();
        store.close();
        await tester.runAsync(() async {
          await PdfrxEntryFunctions.instance.stopBackgroundWorker();
          await temporary.delete(recursive: true);
        });
      }
    },
    skip: [layout, formula, rules, pdf].any((v) => v == null),
  );
}
