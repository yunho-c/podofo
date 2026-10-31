import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:podoco/podoco.dart' as podoco;
import 'package:podofo_one/objectbox.g.dart';
import 'package:podofo_one/src/data/objectbox.dart';
import 'package:podofo_one/src/analysis/analysis_controller.dart';
import 'package:podofo_one/src/analysis/analysis_engine.dart';
import 'package:podofo_one/src/analysis/analysis_store.dart';
import 'package:podofo_one/src/analysis/preview_layout_store.dart';
import 'package:podofo_one/src/providers/analysis_provider.dart';
import 'package:podofo_one/src/narration/narration_controller.dart';
import 'package:podofo_one/src/providers/data_provider.dart';
import 'package:podofo_one/src/providers/document_provider.dart';
import 'package:podofo_one/src/providers/narration_provider.dart';
import 'package:podofo_one/src/providers/tab_provider.dart';
import 'package:podofo_one/src/services/pdf_session.dart';
import 'package:podofo_one/src/widgets/areas/main_area.dart';
import 'package:podofo_one/src/widgets/components/pdf_link_hover_preview.dart';
import 'package:podofo_one/src/workers/link_preview_worker.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures/hover_pdf_fixture.dart';
import 'support/fake_narrator.dart';
import 'analysis_native_test.dart' show ControlledEngine, ControlledJob;

void main() {
  final platform = TargetPlatformVariant.only(
    Platform.isMacOS ? TargetPlatform.macOS : TargetPlatform.windows,
  );
  testWidgets(
    'settled hover refines its label without selecting the target analysis page',
    (tester) async {
      final reader = await _Reader.open(tester, semanticFixture: true);
      final matrix = reader.viewer.value.clone();
      final point = await reader.linkPoint(2);
      await reader.mouse.moveTo(point);
      await tester.pump(const Duration(milliseconds: 349));
      expect(reader.semanticEngine!.pages, isEmpty);
      await tester.pump(const Duration(milliseconds: 1));
      await _wait(
        tester,
        () => find.text('Figure 4 · Page 2').evaluate().isNotEmpty,
      );
      expect(reader.semanticEngine!.pages, [1]);
      expect(reader.viewer.value, matrix);
      expect(reader.viewer.pageNumber, 1);
      expect(reader.session.navigationHistory.previous, isNull);
      expect(reader.analysis!.visibleSnapshot, isNull);
      expect(reader.session.revision, 0);
      await reader.mouse.moveTo(point + const Offset(1, 0));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await _wait(
        tester,
        () => find.text('Figure 4 · Page 2').evaluate().isNotEmpty,
      );
      expect(reader.semanticEngine!.pages, [1]);
      await reader.mouse.down(point);
      await tester.pump();
      expect(find.byType(PdfLinkHoverPreview), findsNothing);
      await reader.mouse.up();
      await _wait(
        tester,
        () => reader.session.navigationHistory.previous != null,
      );
      expect(tester.takeException(), isNull);
    },
    variant: platform,
  );
  testWidgets(
    'real linked previews leave viewport/history intact and clicks still navigate',
    (tester) async {
      final reader = await _Reader.open(tester);
      final matrix = reader.viewer.value.clone();
      final page = reader.viewer.pageNumber;
      final point = await reader.linkPoint(0);
      await reader.mouse.moveTo(point);
      await tester.pump(const Duration(milliseconds: 349));
      expect(find.byType(PdfLinkHoverPreview), findsNothing);
      await tester.pump(const Duration(milliseconds: 1));
      await _wait(tester, () => _preview.evaluate().isNotEmpty);
      expect(reader.viewer.value, matrix);
      expect(reader.viewer.pageNumber, page);
      expect(reader.session.navigationHistory.previous, isNull);
      expect(reader.session.revision, 0);

      // Repeated hovering reuses a detached image without changing reading state.
      await reader.mouse.moveTo(point + const Offset(1, 0));
      await tester.pump();
      expect(_preview, findsNothing);
      await tester.pump(const Duration(milliseconds: 350));
      await _wait(tester, () => _preview.evaluate().isNotEmpty);
      expect(reader.viewer.value, matrix);

      // An external link retains its label and never displays a page raster.
      await reader.mouse.moveTo(await reader.linkPoint(6));
      await tester.pump(const Duration(milliseconds: 350));
      await _wait(
        tester,
        () => find.text('https://example.com/reference').evaluate().isNotEmpty,
      );
      expect(_preview, findsNothing);

      await reader.mouse.moveTo(point);
      await tester.pump(const Duration(milliseconds: 350));
      await _wait(tester, () => _preview.evaluate().isNotEmpty);
      await reader.mouse.down(point);
      await tester.pump(const Duration(milliseconds: 20));
      expect(_preview, findsNothing);
      await reader.mouse.up();
      await _wait(
        tester,
        () => reader.session.navigationHistory.previous != null,
      );
      await tester.pump(const Duration(milliseconds: 250));
      expect(reader.viewer.pageNumber, 2);
      final back = find.byKey(const ValueKey('pdf-link-back'));
      await reader.mouse.moveTo(
        tester.getTopLeft(find.byType(PdfViewer)) + const Offset(2, 2),
      );
      await tester.pump(const Duration(milliseconds: 120));
      await tester.tap(back);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      for (var i = 0; i < 16; i++) {
        expect(reader.viewer.value.storage[i], closeTo(matrix.storage[i], .01));
      }
      expect(reader.session.navigationHistory.previous, isNull);
      expect(tester.takeException(), isNull);
    },
    variant: platform,
  );

  testWidgets(
    'movement, tab changes, close and scroll reject stale hover results',
    (tester) async {
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawColor(const Color(0xffff0000), ui.BlendMode.src);
      final picture = recorder.endRecording();
      final image = (await tester.runAsync(() => picture.toImage(100, 100)))!;
      picture.dispose();
      addTearDown(image.dispose);
      final first = Completer<ui.Image?>();
      var calls = 0;
      LinkPreviewCancellation? cancellation;
      final reader = await _Reader.open(
        tester,
        render: (pdf, dest, ratio, token) async {
          calls++;
          cancellation = token;
          return calls == 1 ? first.future : image.clone();
        },
      );
      final initialSession = reader.session;
      await reader.mouse.moveTo(await reader.linkPoint(0));
      await tester.pump(const Duration(milliseconds: 350));
      await _wait(tester, () => calls == 1);
      await reader.mouse.moveTo(const Offset(1, 1));
      await tester.pump();
      expect(cancellation!.isCancelled, true);
      expect(find.byType(PdfLinkHoverPreview), findsNothing);

      final other = File('${reader.temporary.path}/second.pdf')
        ..writeAsBytesSync(hoverPdfFixture());
      await tester.runAsync(() => reader.documents.addDocument(other.path));
      await reader.loadSourceLinks();
      await reader.ready();
      expect(reader.session, isNot(same(initialSession)));
      final stale = image.clone();
      first.complete(stale);
      await _wait(tester, () => stale.debugDisposed);
      expect(_preview, findsNothing);
      expect(find.byType(PdfLinkHoverPreview), findsNothing);

      await reader.mouse.moveTo(await reader.linkPoint(0));
      await tester.pump(const Duration(milliseconds: 350));
      await _wait(tester, () => _preview.evaluate().isNotEmpty);
      expect(calls, 2); // Same bytes in another session cannot reuse its image.
      reader.container.read(currentTabIndexProvider.notifier).state = 0;
      await tester.pump();
      // Overlay removal during the keyed viewer's disposal schedules a frame.
      await tester.pump();
      expect(find.byType(PdfLinkHoverPreview), findsNothing);
      await reader.ready();
      await reader.mouse.moveTo(await reader.linkPoint(0));
      await tester.pump(const Duration(milliseconds: 350));
      await _wait(tester, () => _preview.evaluate().isNotEmpty);
      await reader.viewer.goToPage(pageNumber: 2, duration: Duration.zero);
      await tester.pump();
      expect(find.byType(PdfLinkHoverPreview), findsNothing);

      await reader.viewer.goToPage(pageNumber: 1, duration: Duration.zero);
      await tester.pump();
      await reader.mouse.moveTo(await reader.linkPoint(0));
      await tester.pump(const Duration(milliseconds: 350));
      await _wait(tester, () => _preview.evaluate().isNotEmpty);
      await _native(
        tester,
        () => reader.documents.removeDocument(reader.session.path),
      );
      await reader.ready();
      expect(initialSession.lease.isClosed, true);
      expect(find.byType(PdfLinkHoverPreview), findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: platform,
  );
}

final _preview = find.byKey(const ValueKey('pdf-link-preview-image'));

Future<void> _wait(WidgetTester tester, bool Function() condition) async {
  for (var i = 0; i < 150; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 20));
    if (condition()) return;
  }
  fail('Timed out waiting for reader/native work');
}

// Preparation now continues after the raster appears. Keep pumping the fake
// timer zone while native work drains; runAsync alone cannot advance its timers.
Future<T> _native<T>(WidgetTester tester, Future<T> Function() action) async {
  var done = false;
  late T result;
  Object? error;
  action().then(
    (value) {
      result = value;
      done = true;
    },
    onError: (Object e) {
      error = e;
      done = true;
    },
  );
  await _wait(tester, () => done);
  if (error != null) throw error!;
  return result;
}

class _Reader {
  _Reader(this.tester, this.temporary, this.container);
  final WidgetTester tester;
  final Directory temporary;
  final ProviderContainer container;
  late final TestGesture mouse;
  AnalysisController? analysis;
  _LayoutEngine? semanticEngine;
  PdfViewerController get viewer => container.read(pdfViewerControllerProvider);
  PdfSession get session => container.read(currentDocumentProvider)!.session;
  LoadedDocumentsNotifier get documents =>
      container.read(loadedDocumentsProvider.notifier);

  static Future<_Reader> open(
    WidgetTester tester, {
    LinkPreviewRenderer? render,
    bool semanticFixture = false,
  }) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final temporary = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('podofo-hover-'),
    ))!;
    await tester.runAsync(() => pdfrxInitialize(tmpPath: temporary.path));
    final file = File('${temporary.path}/first.pdf')
      ..writeAsBytesSync(
        semanticFixture
            ? File('test/fixtures/target_preview/linked_objects.pdf')
                  .readAsBytesSync()
            : hoverPdfFixture(),
      );
    final store = Store(getObjectBoxModel(), directory: '${temporary.path}/db');
    final narrator = NarrationController(
      open: (_) async => FakeNarratorSession(),
    );
    final engine = semanticFixture ? _LayoutEngine() : null;
    final analysis = engine == null
        ? null
        : AnalysisController(
            store: AnalysisStore(Directory('${temporary.path}/manual')),
            previewStore: PreviewLayoutStore(
              Directory('${temporary.path}/previews'),
            ),
            openBundledLayout: (_) async => engine,
            inspectPreviewProfile: () async => PreviewLayoutProfile(
              layoutManifest: engine.manifests.single,
              layoutProfile: engine.profile,
              computePolicy: podoco.ComputePolicy.cpuAndNeuralEngine,
            ),
          );
    final container = ProviderContainer(
      overrides: [
        objectboxProvider.overrideWithValue(ObjectBox(store)),
        narrationControllerProvider.overrideWithValue(narrator),
        if (analysis != null)
          analysisControllerProvider.overrideWith((ref) async {
            ref.listen(currentDocumentProvider, (_, document) {
              analysis.select(
                document?.session,
                (document?.lastOpenedPage ?? 1) - 1,
              );
            }, fireImmediately: true);
            return analysis;
          }),
        if (render != null)
          linkPreviewRendererProvider.overrideWithValue(render),
      ],
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(narrator.close);
      container.dispose();
      if (analysis != null) {
        await _native(tester, analysis.close);
        analysis.dispose();
      }
      store.close();
      await _native(tester, () async {
        await PdfrxEntryFunctions.instance.stopBackgroundWorker();
        await temporary.delete(recursive: true);
      });
    });
    final reader = _Reader(tester, temporary, container);
    reader.analysis = analysis;
    reader.semanticEngine = engine;
    await tester.runAsync(() => reader.documents.addDocument(file.path));
    await reader.loadSourceLinks();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const shadcn.ShadcnApp(home: MainArea()),
      ),
    );
    reader.mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await reader.mouse.addPointer(location: Offset.zero);
    addTearDown(reader.mouse.removePointer);
    await reader.ready();
    return reader;
  }

  Future<void> ready() async {
    await _wait(tester, () => container.read(pdfTextSearcherProvider) != null);
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> loadSourceLinks() async {
    // Prime the real annotation cache before mounting the viewer. Waiting on a
    // link job started inside Flutter's fake timer zone from runAsync can stall
    // the PDFium worker; this is test scheduling, not a production dependency.
    await tester.runAsync(
      () => session.readLocked((pdf) => pdf.pages.first.loadLinks()),
    );
  }

  Future<Offset> linkPoint(int index) async {
    final page = session.lease.document.pages.first;
    final links = await _native(
      tester,
      () => session.readLocked((_) => page.loadLinks()),
    );
    final rect = links[index].rects.single.toRectInDocument(
      page: page,
      pageRect: viewer.layout.pageLayouts.first,
    );
    final point = viewer.documentToGlobal(rect.center)!;
    expect(tester.getRect(find.byType(PdfViewer)).contains(point), true);
    return point;
  }
}

class _LayoutEngine extends ControlledEngine {
  final pages = <int>[];
  final snapshot =
      jsonDecode(
            File(
              'test/fixtures/target_preview/layout/linked_objects-page-2.json',
            ).readAsStringSync(),
          )['snapshot']
          as Map;
  @override
  String get profile => snapshot['page']['provenance']['pipeline']['profile'];
  @override
  List<String> get manifests => [
    snapshot['page']['provenance']['pipeline']['models'][0]['manifest_sha256'],
  ];
  @override
  podoco.ComputePolicy get computePolicy =>
      podoco.ComputePolicy.cpuAndNeuralEngine;
  @override
  Future<void> close() async {
    closeCount++;
  }

  @override
  DocumentAnalysisJob analyzePage(
    podoco.PageSource source,
    int pageIndex,
    Future<void> Function(podoco.AnalysisUpdate) sink, {
    podoco.FormulaScope formulaScope = podoco.FormulaScope.none,
  }) {
    expect(formulaScope, podoco.FormulaScope.none);
    pages.add(pageIndex);
    final job = ControlledJob();
    final page =
        jsonDecode(jsonEncode(snapshot['page'])) as Map<String, dynamic>;
    page['page']['key'] = source.pages[pageIndex].key.toJson();
    unawaited(
      Future<void>(() async {
        try {
          await sink(
            podoco.AnalysisUpdate.fromJson({
              'schema_version': 0,
              'analysis_id': job.id,
              'document': source.document.toJson(),
              'sequence': 0,
              'payload': {'type': 'page_layout_ready', 'page': page},
            }),
          );
        } finally {
          job.finish();
        }
      }),
    );
    return job;
  }
}
