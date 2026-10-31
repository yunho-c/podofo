import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:podoco/podoco.dart' as podoco;
import 'package:podoco_flutter/podoco_flutter.dart';
import 'package:podofo_one/src/analysis/analysis_controller.dart';
import 'package:podofo_one/src/analysis/analysis_coordinator.dart';
import 'package:podofo_one/src/analysis/analysis_engine.dart';
import 'package:podofo_one/src/analysis/analysis_store.dart';
import 'package:podofo_one/src/analysis/pdf_analysis_source.dart';
import 'package:podofo_one/src/analysis/pdf_image_input.dart';
import 'package:podofo_one/src/analysis/preview_layout_store.dart';
import 'package:podofo_one/src/previews/link_target.dart';
import 'package:podofo_one/src/services/pdf_session.dart';
import 'package:podofo_one/src/workers/link_preview_worker.dart';

import 'support/file_access_mock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'bundled cold/warm/restarted hover and manual upgrade drain real native models',
    () async {
      installFileAccessMock();
      final root = await Directory.systemTemp.createTemp('preview-native-');
      await pdfrxInitialize(tmpPath: root.path);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        NativeModelResources.channel,
        (call) async => call.method == 'platform'
            ? 'macos-arm64'
            : Directory('.podoco/model_assets/models').absolute.path,
      );
      final session = await PdfSession.open(
        'test/fixtures/target_preview/linked_objects.pdf',
      );
      final manual = AnalysisStore(Directory('${root.path}/manual'));
      final preview = PreviewLayoutStore(Directory('${root.path}/preview'));
      final worker = LinkPreviewWorker();
      var layoutOpens = 0, combinedOpens = 0;
      final report = <String, Object?>{};
      AnalysisController create() => AnalysisController(
        store: manual,
        previewStore: preview,
        openBundledLayout: (progress) async {
          layoutOpens++;
          final timer = Stopwatch()..start();
          final engine = await NativeAnalysisEngine.openBundledLayout(progress);
          report['layout_open_us'] = timer.elapsedMicroseconds;
          expect(engine.recognizesFormulas, false);
          expect(engine.manifests, hasLength(1));
          report['layout_manifests'] = engine.manifests;
          return engine;
        },
        openBundled: (progress) async {
          combinedOpens++;
          expect(
            podoco.nativeLiveHandles,
            0,
            reason: 'Layout engine must close before combined open',
          );
          final timer = Stopwatch()..start();
          final engine = await NativeAnalysisEngine.openBundled(progress);
          report['combined_open_us'] = timer.elapsedMicroseconds;
          expect(engine.recognizesFormulas, true);
          expect(engine.manifests, hasLength(2));
          return engine;
        },
      )..select(session, 0);
      var analysis = create();
      final link = (await session.lease.document.pages.first.loadLinks())[2];
      final request = LinkPreviewRequest(
        session: session,
        sourcePage: 1,
        annotationIndex: 2,
        sourceRects: link.rects,
        destination: link.dest!,
        pixelRatio: 1,
      );
      Future<void> hover(String name) async {
        final timer = Stopwatch()..start();
        final semantic = Completer<(ui.Image, ResolvedLinkTarget)>();
        final baseline = await worker.load(
          session,
          link.dest!,
          pixelRatio: 1,
          request: request,
          repository: analysis.previewRepository,
          onRefinement: (image, target) => semantic.complete((image, target)),
        );
        report['${name}_context_us'] = timer.elapsedMicroseconds;
        expect(baseline, isNotNull);
        baseline!.dispose();
        final (image, target) = await semantic.future.timeout(
          const Duration(seconds: 30),
        );
        try {
          report['${name}_total_us'] = timer.elapsedMicroseconds;
          expect(target.label, 'Figure 4');
          expect(target.parts.single.page, 2);
          expect(image.width, lessThanOrEqualTo(360));
          expect(image.height, lessThanOrEqualTo(240));
        } finally {
          image.dispose();
        }
      }

      try {
        expect(podoco.nativeLiveHandles, 0);
        await hover('cold');
        expect(analysis.visibleSnapshot, isNull);
        expect(analysis.ready, false);
        expect(combinedOpens, 0);
        expect(layoutOpens, 1);
        expect(session.revision, 0);
        expect(session.navigationHistory.previous, isNull);
        final cachedFiles = await preview.directory
            .list()
            .where((e) => e is File)
            .toList();
        expect(cachedFiles, hasLength(1));
        expect(cachedFiles.single.path, endsWith('-1.json'));
        expect(await manual.directory.exists(), false);
        worker.reset();
        await hover('warm');
        expect(layoutOpens, 1);
        await analysis.analyze();
        expect(analysis.error, isNull);
        expect(analysis.outcome!.status, podoco.CompletionStatus.completed);
        expect(combinedOpens, 1);
        expect(analysis.recognizesFormulas, true);
        final visible = analysis.visibleSnapshot;
        final manualBytes = <File, String>{};
        await for (final entry in manual.directory.list()) {
          if (entry is File) manualBytes[entry] = await entry.readAsString();
        }
        expect(
          manualBytes.values.any((v) => v.contains('"status":"recognized"')),
          true,
        );
        worker.reset();
        await hover('after_manual');
        expect(analysis.visibleSnapshot, same(visible));
        for (final entry in manualBytes.entries) {
          expect(await entry.key.readAsString(), entry.value);
        }
        worker.reset();
        await analysis.close();
        analysis.dispose();
        expect(podoco.nativeLiveHandles, 0);
        analysis = create();
        await hover('restart');
        expect(
          layoutOpens,
          1,
          reason: 'Restart must reuse persisted layout without opening a model',
        );
        expect(combinedOpens, 1);
        worker.reset();
        await analysis.close();
        expect(podoco.nativeLiveHandles, 0);
        final transfers = AnalysisImageTransfers();
        final ready = Completer<void>(), releaseImage = Completer<void>();
        const paths = AnalysisModelPaths('.podoco/model_assets/models/layout');
        final closingCoordinator = AnalysisCoordinator(
          store: PreviewLayoutStore(Directory('${root.path}/closing')),
          manualStore: manual,
          manualEngine: () => null,
          inspectProfile: () => NativeAnalysisEngine.previewProfile(paths),
          openLayout: () => NativeAnalysisEngine.open(paths),
          createSource: (session) async => _GatedSource(
            await PdfAnalysisSource.create(session, transfers: transfers),
            ready,
            releaseImage,
          ),
        );
        try {
          final pending = closingCoordinator.request(request, () => true);
          await ready.future.timeout(const Duration(seconds: 30));
          expect(transfers.liveBytes, greaterThan(0));
          await session
              .close(); // Input lease is independent from the PDF document.
          var closed = false;
          final closing = closingCoordinator.close().then((_) => closed = true);
          expect(await pending.result, isNull);
          await Future<void>.delayed(Duration.zero);
          expect(closed, false);
          releaseImage.complete();
          await closing.timeout(const Duration(seconds: 30));
          expect(transfers.leased, 1);
          expect(transfers.released, transfers.leased);
          expect(transfers.liveBytes, 0);
          expect(podoco.nativeLiveHandles, 0);
          report['cancelled_renderer_leases_released'] = transfers.released;
        } finally {
          if (!releaseImage.isCompleted) releaseImage.complete();
          await closingCoordinator.close();
        }
        report['layout_opens'] = layoutOpens;
        report['combined_opens'] = combinedOpens;
        report['native_handles_after_close'] = podoco.nativeLiveHandles;
        final out = Directory('build/target-preview-m3')
          ..createSync(recursive: true);
        await File('${out.path}/native-lifecycle.json')
            .writeAsString(const JsonEncoder.withIndent('  ').convert(report));
      } finally {
        worker.dispose();
        await analysis.close();
        analysis.dispose();
        await session.close();
        messenger.setMockMethodCallHandler(NativeModelResources.channel, null);
        await PdfrxEntryFunctions.instance.stopBackgroundWorker();
        await root.delete(recursive: true);
      }
    },
    skip: Platform.environment['PODOCO_PREVIEW_NATIVE'] != '1',
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

class _GatedSource implements podoco.PageSource {
  _GatedSource(this.source, this.ready, this.release);
  final PdfAnalysisSource source;
  final Completer<void> ready, release;
  @override
  podoco.DocumentRef get document => source.document;
  @override
  List<podoco.PageDescriptor> get pages => source.pages;
  @override
  Future<podoco.PageInput> loadPage(podoco.PageRequest request) async {
    final input = await source.loadPage(request);
    ready.complete();
    await release.future;
    return input;
  }
}
