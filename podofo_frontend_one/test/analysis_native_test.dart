import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:podoco/podoco.dart' as podoco;
import 'package:podofo_one/src/analysis/analysis_controller.dart';
import 'package:podofo_one/src/analysis/analysis_store.dart';
import 'package:podofo_one/src/analysis/layout_engine.dart';
import 'package:podofo_one/src/analysis/pdf_analysis_source.dart';
import 'package:podofo_one/src/services/pdf_session.dart';

import 'fixtures/analysis_fixture.dart';
import 'fixtures/pdf_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporary;
  setUpAll(() async {
    temporary = await Directory.systemTemp.createTemp('podoco-app-native-');
    await pdfrxInitialize(tmpPath: temporary.path);
  });
  tearDownAll(() async {
    await PdfrxEntryFunctions.instance.stopBackgroundWorker();
    await temporary.delete(recursive: true);
  });
  Future<PdfSession> session(String name) async {
    final file = File('${temporary.path}/$name.pdf');
    await file.writeAsBytes(pdfFixture());
    return PdfSession.open(file.path);
  }

  test(
    'raster budget and displayed geometry agree across crop and all rotations',
    () async {
      for (final rotation in [0, 90, 180, 270]) {
        final pdf = await PdfDocument.openData(
          pdfFixture(rotatedPageDegrees: rotation),
        );
        try {
          for (final page in pdf.pages) {
            final size = analysisRasterSize(
              page.width,
              page.height,
              16 * 1024 * 1024,
            );
            final image = (await page.render(
              width: size.width,
              height: size.height,
              fullWidth: size.width.toDouble(),
              fullHeight: size.height.toDouble(),
              annotationRenderingMode: PdfAnnotationRenderingMode.none,
            ))!;
            try {
              final structured = await page.loadStructuredText();
              final text = PdfPageTextRange(
                pageText: structured,
                start: 0,
                end: structured.fullText.length,
              );
              final bounds = text.bounds.toRect(page: page);
              final space = podoco.PageSpace(page.width, page.height);
              final canvas = Rect.fromLTWH(
                13,
                21,
                page.width * 2,
                page.height * 2,
              );
              final mapped = analysisRect(
                podoco.PageRect(
                  bounds.left,
                  bounds.top,
                  bounds.right,
                  bounds.bottom,
                ),
                space,
                canvas,
              );
              expect(
                mapped,
                text.bounds
                    .toRect(page: page, scaledPageSize: canvas.size)
                    .translate(canvas.left, canvas.top),
              );
              expect(
                analysisRect(
                  podoco.PageRect(0, 0, space.width, space.height),
                  space,
                  canvas,
                ),
                canvas,
              );
              // Text geometry must cover actual dark raster pixels in every orientation.
              var dark = 0, covered = 0;
              final pixels = image.pixels;
              for (var y = 0; y < image.height; y++) {
                for (var x = 0; x < image.width; x++) {
                  final offset = (y * image.width + x) * 4;
                  if (pixels[offset] < 100 &&
                      pixels[offset + 1] < 100 &&
                      pixels[offset + 2] < 100) {
                    dark++;
                    if (bounds
                        .inflate(2)
                        .contains(
                          Offset(
                            (x + .5) * page.width / image.width,
                            (y + .5) * page.height / image.height,
                          ),
                        )) {
                      covered++;
                    }
                  }
                }
              }
              expect(dark, greaterThan(100));
              expect(covered / dark, greaterThan(.99));
            } finally {
              image.dispose();
            }
          }
        } finally {
          await pdf.dispose();
        }
      }
      final bounded = analysisRasterSize(10000, 10000, 40000);
      expect(bounded.width * bounded.height * 4, lessThanOrEqualTo(40000));
    },
  );

  test(
    'document switch, close and revision changes reject late updates',
    () async {
      final first = await session('first'), second = await session('second');
      final engine = ControlledEngine();
      final store = AnalysisStore(
        Directory('${temporary.path}/controller-cache'),
      );
      final controller = AnalysisController(
        store: store,
        open: (_) async => engine,
      );
      try {
        controller.select(first, 0);
        await controller.configure('fixture');
        final operation = controller.analyze();
        await engine.started.future;
        final original = analysisDocumentRef(first);
        await engine.sink(analysisFixture(original));
        expect(controller.visibleUpdate, isA<podoco.PageLayoutReady>());
        controller.select(second, 0);
        expect(engine.job.cancelled, true);
        await engine.sink(analysisFixture(original, finished: true));
        expect(controller.visibleUpdate, isNull);
        engine.job.finish();
        await operation;
        final key = analysisCacheKey(original, fixtureManifest, fixtureProfile);
        expect(
          await store.read(key, 0, original),
          isA<podoco.PageLayoutReady>(),
        );
        await first.close();
        final reopened = await PdfSession.open(first.path);
        try {
          expect(analysisDocumentRef(reopened), original);
          first.revision = 1;
          reopened.revision = 1;
          expect(
            analysisDocumentRef(reopened),
            isNot(analysisDocumentRef(first)),
          );
          controller.select(reopened, 0);
          await reopened.close();
          expect(reopened.lease.isClosed, true);
        } finally {
          await reopened.close(discard: true);
        }
      } finally {
        engine.job.finish();
        await controller.close();
        controller.dispose();
        await first.close(discard: true);
        await second.close(discard: true);
      }
    },
  );

  for (final change in ['edit', 'close']) {
    test(
      'late updates after $change are rejected without a UI refresh',
      () async {
        final pdf = await session('late-$change');
        final engine = ControlledEngine();
        final store = AnalysisStore(
          Directory('${temporary.path}/late-$change'),
        );
        final controller = AnalysisController(
          store: store,
          open: (_) async => engine,
        );
        try {
          controller.select(pdf, 0);
          await controller.configure('fixture');
          final operation = controller.analyze();
          await engine.started.future;
          final original = analysisDocumentRef(pdf);
          if (change == 'edit') {
            pdf.revision++;
          } else {
            await pdf.close();
          }
          await engine.sink(analysisFixture(original, finished: true));
          expect(controller.visibleUpdate, isNull);
          final key = analysisCacheKey(
            original,
            fixtureManifest,
            fixtureProfile,
          );
          expect(await store.read(key, 0, original), isNull);
          engine.job.finish();
          await operation;
        } finally {
          engine.job.finish();
          await controller.close();
          controller.dispose();
          await pdf.close(discard: true);
        }
      },
    );
  }

  test(
    'cancellation while waiting for the PDF lock prevents job admission',
    () async {
      final pdf = await session('cancel-lock');
      final engine = ControlledEngine();
      final controller = AnalysisController(
        store: AnalysisStore(Directory('${temporary.path}/cancel-lock-cache')),
        open: (_) async => engine,
      );
      final blocked = Completer<void>(), entered = Completer<void>();
      final locked = pdf.readLocked((_) async {
        entered.complete();
        await blocked.future;
      });
      await entered.future;
      try {
        controller.select(pdf, 0);
        await controller.configure('fixture');
        final task = controller.analyze();
        controller.cancel();
        blocked.complete();
        await locked;
        await task;
        expect(engine.started.isCompleted, false);
      } finally {
        if (!blocked.isCompleted) blocked.complete();
        // No job was admitted, so the fake engine has no done listener.
        engine.job.completion.future.ignore();
        await controller.close();
        controller.dispose();
        await pdf.close();
      }
    },
  );

  test(
    'repeated close waits for a model still opening and disposes it once',
    () async {
      final opened = Completer<LayoutEngine>();
      final engine = ControlledEngine();
      engine.job.completion.future.ignore();
      final controller = AnalysisController(
        store: AnalysisStore(Directory('${temporary.path}/opening-cache')),
        open: (_) => opened.future,
      );
      final configuration = controller.configure('fixture');
      final closing = controller.close();
      expect(identical(closing, controller.close()), true);
      opened.complete(engine);
      await configuration;
      await closing;
      expect(engine.closeCount, 1);
      controller.dispose();
    },
  );

  final bundle = Platform.environment['PODOCO_M2_BUNDLE'];
  test(
    'real PDF source and persistent app controller complete and reopen three pages',
    () async {
      final pdf = await session('real-layout');
      final controller = AnalysisController(
        store: AnalysisStore(Directory('${temporary.path}/real-cache')),
      );
      try {
        controller.select(pdf, 0);
        await controller.configure(bundle!);
        expect(controller.error, isNull);
        await controller.analyze();
        expect(controller.error, isNull);
        expect(controller.outcome?.status, podoco.CompletionStatus.completed);
        expect(controller.outcome?.summary.counts.pagesFinished, 3);
        expect(
          controller.outcome?.progress.peakInputBytes,
          lessThanOrEqualTo(16 * 1024 * 1024),
        );
        for (var i = 0; i < 3; i++) {
          controller.select(pdf, i);
          await waitFor(
            () =>
                controller.pageComplete &&
                controller.visiblePage?.page.key.pageIndex == i,
          );
          final page = controller.visiblePage!;
          expect(page.regions, isNotEmpty);
          expect(page.page.space.toJson(), [
            pdf.lease.document.pages[i].width,
            pdf.lease.document.pages[i].height,
          ]);
          expect(page.provenance.renderProfile, layoutRenderProfile);
          final map = page.provenance.pixelToPage.values;
          expect(
            map[0] * page.provenance.image.width,
            closeTo(page.page.space.width, 1e-9),
          );
          expect(
            map[3] * page.provenance.image.height,
            closeTo(page.page.space.height, 1e-9),
          );
        }
        controller.select(null, 0);
        await pdf.close();
        final reopened = await PdfSession.open(pdf.path);
        try {
          controller.select(reopened, 1);
          await waitFor(() => controller.pageComplete);
          expect(
            controller.visiblePage!.page.key.document,
            analysisDocumentRef(reopened),
          );
        } finally {
          controller.select(null, 0);
          await reopened.close();
        }
        final longFile = File('${temporary.path}/long.pdf');
        await longFile.writeAsBytes(repeatedTextPdfFixture(64));
        final longPdf = await PdfSession.open(longFile.path);
        try {
          controller.select(longPdf, 0);
          await controller.analyze();
          expect(controller.error, isNull);
          expect(controller.outcome?.summary.counts.pagesFinished, 64);
          expect(
            controller.outcome?.progress.peakInputBytes,
            lessThanOrEqualTo(16 * 1024 * 1024),
          );
          expect(controller.outcome?.progress.inputBytes, 0);
          expect(controller.outcome?.progress.pendingResultBytes, 0);
          expect(controller.visiblePage?.page.key.pageIndex, 0);
        } finally {
          controller.select(null, 0);
          await longPdf.close();
        }
      } finally {
        await controller.close();
        controller.dispose();
        await pdf.close();
      }
      expect(podoco.nativeLiveHandles, 0);
    },
    skip: bundle == null
        ? 'Set PODOCO_M2_BUNDLE for explicit native model qualification.'
        : false,
  );
}

Future<void> waitFor(bool Function() condition) async {
  final end = DateTime.now().add(const Duration(seconds: 15));
  while (!condition()) {
    if (DateTime.now().isAfter(end)) {
      fail('Timed out waiting for analysis state');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class ControlledEngine implements LayoutEngine {
  int closeCount = 0;
  final started = Completer<void>();
  final job = ControlledJob();
  late Future<void> Function(podoco.AnalysisUpdate) sink;
  @override
  String get manifest => fixtureManifest;
  @override
  String get profile => fixtureProfile;
  @override
  LayoutJob analyze(
    podoco.PageSource pages,
    Future<void> Function(podoco.AnalysisUpdate) sink,
  ) {
    this.sink = sink;
    started.complete();
    return job;
  }

  @override
  Future<void> close() async {
    closeCount++;
    job.finish();
  }
}

class ControlledJob implements LayoutJob {
  final completion = Completer<podoco.AnalysisOutcome>();
  bool cancelled = false;
  @override
  String get id => 'fixture-job';
  @override
  Future<podoco.AnalysisOutcome> get done => completion.future;
  @override
  Stream<podoco.AnalysisProgress> get progress => const Stream.empty();
  @override
  void cancel() {
    cancelled = true;
  }

  void finish() {
    if (!completion.isCompleted) {
      completion.completeError(StateError('controlled drain'));
    }
  }
}
