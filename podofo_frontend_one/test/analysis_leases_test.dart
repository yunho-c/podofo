import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:podoco/podoco.dart' as podoco;
import 'package:podofo_one/src/analysis/pdf_analysis_source.dart';
import 'package:podofo_one/src/analysis/pdf_image_input.dart';
import 'package:podofo_one/src/services/pdf_session.dart';

import 'fixtures/pdf_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporary;
  setUpAll(() async {
    temporary = await Directory.systemTemp.createTemp('podoco-leases-');
    await pdfrxInitialize(tmpPath: temporary.path);
  });
  tearDownAll(() async {
    await PdfrxEntryFunctions.instance.stopBackgroundWorker();
    await temporary.delete(recursive: true);
  });
  tearDown(() => expect(podoco.nativeLiveHandles, 0));
  Future<PdfImage> render(PdfDocument pdf) async => (await pdf.pages[0].render(
    width: 520,
    height: 720,
    fullWidth: 520,
    fullHeight: 720,
    backgroundColor: 0xffffffff,
    annotationRenderingMode: PdfAnnotationRenderingMode.none,
  ))!;

  test('exclusive lease survives image and document disposal and releases once', () async {
    final pdf = await PdfDocument.openData(pdfFixture(pageCount: 1));
    final image = await render(pdf);
    final lease = image.tryTakeNativeLease()!;
    final address = lease.address;
    String digest() => sha256
        .convert(
          Pointer<Uint8>.fromAddress(address)
              .asTypedList(lease.initializedBytes),
        )
        .toString();
    final expected = digest();
    expect(lease.retainedBytes, 520 * 720 * 4);
    expect(lease.rowBytes, 520 * 4);
    expect(() => image.pixels, throwsStateError);
    expect(image.tryTakeNativeLease, throwsStateError);
    image.dispose();
    image.dispose();
    await pdf.dispose();
    // Retain the lease under allocation/GC pressure, with no PDF handle alive.
    for (var i = 0; i < 32; i++) {
      final pressure = Uint8List(1024 * 1024)..fillRange(0, 1024 * 1024, i);
      expect(pressure.last, i);
      await Future<void>.delayed(Duration.zero);
    }
    expect(lease.address, address);
    expect(digest(), expected);
    lease.release();
    lease.release();
    expect(lease.isReleased, isTrue);
    expect(() => lease.address, throwsStateError);
  });

  test(
    'escaped writable views and managed images retain the copying fallback',
    () async {
      final pdf = await PdfDocument.openData(pdfFixture(pageCount: 1));
      final image = await render(pdf);
      final exposed = image.pixels;
      expect(image.tryTakeNativeLease(), isNull);
      final transfers = AnalysisImageTransfers();
      final input = analysisImageInput(
        image,
        byteBudget: 2 * 1024 * 1024,
        transfers: transfers,
      );
      exposed[0] = 7; // Only the old renderer storage remains writable.
      image.dispose();
      await pdf.dispose();
      expect(transfers.copied, 1);
      expect(transfers.leased, 0);
      expect(transfers.copiedBytes, 520 * 720 * 4);
      await input.dispose();
      final managed = PdfImage.createFromBgraData(
        Uint8List(16),
        width: 2,
        height: 2,
      );
      expect(managed.tryTakeNativeLease(), isNull);
      final small = analysisImageInput(managed, byteBudget: 16);
      managed.dispose();
      await small.dispose();
    },
  );

  test(
    'native import rejection and success both free their exact renderer lease',
    () async {
      final pdf = await PdfDocument.openData(pdfFixture(pageCount: 1));
      final transfers = AnalysisImageTransfers();
      try {
        final rejected = await render(pdf);
        expect(
          () =>
              analysisImageInput(rejected, byteBudget: 1, transfers: transfers),
          throwsA(
            isA<podoco.PodocoException>().having(
              (e) => e.code,
              'code',
              'limit_exceeded',
            ),
          ),
        );
        rejected.dispose();
        expect(
          [
            transfers.leased,
            transfers.released,
            transfers.rejected,
            transfers.liveBytes,
          ],
          [1, 1, 1, 0],
        );
        final image = await render(pdf);
        final input = analysisImageInput(
          image,
          byteBudget: 2 * 1024 * 1024,
          transfers: transfers,
        );
        image.dispose();
        expect(transfers.liveBytes, 520 * 720 * 4);
        await input.dispose();
        await input.dispose();
        expect(
          [
            transfers.leased,
            transfers.released,
            transfers.liveBytes,
            transfers.copiedBytes,
          ],
          [2, 2, 0, 0],
        );
      } finally {
        await pdf.dispose();
      }
    },
  );

  final layoutPath = Platform.environment['PODOCO_M2_BUNDLE'];
  final formulaPath = Platform.environment['PODOCO_M6_BUNDLE'];
  final actualPdf = Platform.environment['PODOCO_M8_PDF'];
  final evidencePath = Platform.environment['PODOCO_M8_EVIDENCE'];
  test('alternating handoff timing excludes render and release', () async {
    final pdf = await PdfDocument.openFile(actualPdf!);
    final samples = <String, List<int>>{'copy': [], 'lease': []};
    try {
      for (var iteration = 0; iteration < 24; iteration++) {
        for (final leased in iteration.isEven ? [false, true] : [true, false]) {
          final image = (await pdf.pages.first.render(
            width: 1447,
            height: 2048,
            fullWidth: 1447,
            fullHeight: 2048,
            backgroundColor: 0xffffffff,
            annotationRenderingMode: PdfAnnotationRenderingMode.none,
          ))!;
          final transfers = AnalysisImageTransfers();
          final input = analysisImageInput(
            image,
            byteBudget: 16 * 1024 * 1024,
            preferNativeLease: leased,
            transfers: transfers,
          );
          image.dispose();
          if (iteration >= 4) {
            samples[leased ? 'lease' : 'copy']!.add(
              transfers.handoffMicroseconds,
            );
          }
          await input.dispose();
          expect(transfers.liveBytes, 0);
          expect(transfers.leased, transfers.released);
        }
      }
      if (evidencePath != null) {
        await File('$evidencePath.benchmark.json').writeAsString(
          jsonEncode({
            'width': 1447,
            'height': 2048,
            'bytes': 1447 * 2048 * 4,
            'warmup_pairs': 4,
            'alternating_pairs': 20,
            'microseconds': samples,
            'boundary':
                'analysisImageInput only; rendering and release excluded',
          }),
        );
      }
    } finally {
      await pdf.dispose();
    }
  }, skip: actualPdf == null ? 'Requires explicit renderer corpus' : false);

  group(
    'native lease jobs',
    () {
      late PdfSession pdf;
      late podoco.Analyzer analyzer;
      setUp(() async {
        final path = '${temporary.path}/jobs.pdf';
        if (actualPdf == null) {
          await File(path).writeAsBytes(pdfFixture());
        } else {
          await File(actualPdf).copy(path);
        }
        pdf = await PdfSession.open(path);
        analyzer = await podoco.Analyzer.open(
          await podoco.ModelBundle.verify(layoutPath!),
          formulaBundle: formulaPath == null
              ? null
              : await podoco.FormulaBundle.verify(formulaPath),
          options: podoco.AnalyzerOptions(
            computePolicy: podoco.ComputePolicy.cpuAndNeuralEngine,
            limits: podoco.ResourceLimits(
              queuedJobs: 1,
              inputBytes: 16 * 1024 * 1024,
              pendingUpdates: 1,
              resultBytes: 4 * 1024 * 1024,
              maxUpdateBytes: 2 * 1024 * 1024,
              tensorBytes: 128 * 1024 * 1024,
              decoderCacheBytes: 48 * 1024 * 1024,
            ),
          ),
        );
      });
      tearDown(() async {
        await analyzer.dispose();
        await pdf.close();
      });
      podoco.AnalysisOptions options() => podoco.AnalysisOptions(
        profile: analyzer.profile,
        formulaScope: formulaPath == null
            ? podoco.FormulaScope.none
            : podoco.FormulaScope.all,
      );

      test(
        'copied and leased real renderer jobs match with a slow sink',
        () async {
          final records = <List<Map<String, Object?>>>[];
          final counters = <Map<String, Object?>>[];
          var recognized = 0;
          for (final leased in [false, true]) {
            final transfers = AnalysisImageTransfers();
            final source = await PdfAnalysisSource.create(
              pdf,
              preferNativeLease: leased,
              transfers: transfers,
            );
            final updates = <Map<String, Object?>>[];
            final job = analyzer.analyzeDocument(
              pages: source,
              options: options(),
              onUpdate: (u) async {
                if (u is podoco.FormulaFinished &&
                    u.outcome is podoco.FormulaRecognized) {
                  recognized++;
                }
                updates.add(
                  Map<String, Object?>.from(u.toJson()['payload'] as Map),
                );
                await Future<void>.delayed(const Duration(milliseconds: 20));
              },
            );
            final outcome = await job.done;
            await job.dispose();
            expect(outcome.status, podoco.CompletionStatus.completed);
            expect(transfers.liveBytes, 0);
            expect(transfers.leased, transfers.released);
            expect(leased ? transfers.copied : transfers.leased, 0);
            expect(
              leased ? transfers.leased : transfers.copied,
              source.pages.length,
            );
            expect(outcome.progress.inputBytes, 0);
            records.add(updates);
            counters.add({
              'leased': leased,
              'pages': source.pages.length,
              'renderer_leases': transfers.leased,
              'released': transfers.released,
              'copies_per_handoff': leased ? 0 : 2,
              'bytes_per_copy_path': transfers.copiedBytes,
              'peak_live_renderer_bytes': transfers.peakBytes,
              'handoff_microseconds': transfers.handoffMicroseconds,
              'peak_job_input_bytes': outcome.progress.peakInputBytes,
            });
          }
          expect(records[1], records[0]);
          if (formulaPath != null && actualPdf != null) {
            expect(recognized, greaterThan(0));
          }
          if (evidencePath != null) {
            await File(evidencePath).writeAsString(
              jsonEncode({
                'parity': true,
                'recognized': recognized,
                'handoffs': counters,
                'payloads': records.first,
              }),
            );
          }
        },
      );

      test('cancelled late render survives document close and releases before done', () async {
        final transfers = AnalysisImageTransfers();
        final source = DelayedSource(
          await PdfAnalysisSource.create(pdf, transfers: transfers),
        );
        final updates = <podoco.AnalysisUpdate>[];
        final job = analyzer.analyzeDocument(
          pages: source,
          options: options(),
          onUpdate: (u) async {
            updates.add(u);
          },
        );
        try {
          await source.rendered.future;
          expect(transfers.liveBytes, greaterThan(0));
          job.cancel();
          await pdf.close();
          expect(transfers.released, 0);
          source.resume.complete();
          final result = await job.done;
          expect(result.status, podoco.CompletionStatus.cancelled);
          expect(updates.whereType<podoco.PageLayoutReady>(), isEmpty);
          expect(
            [transfers.leased, transfers.released, transfers.liveBytes],
            [1, 1, 0],
          );
        } finally {
          if (!source.resume.isCompleted) source.resume.complete();
          await job.dispose();
        }
      });
      test('sink failure releases renderer storage and preserves worker reuse', () async {
        final transfers = AnalysisImageTransfers();
        final source = await PdfAnalysisSource.create(
          pdf,
          transfers: transfers,
        );
        final job = analyzer.analyzeDocument(
          pages: source,
          options: options(),
          onUpdate: (u) async {
            if (u is podoco.PageLayoutReady) {
              throw StateError('Injected persistence failure');
            }
          },
        );
        final result = await job.done;
        await job.dispose();
        expect(result.status, podoco.CompletionStatus.failed);
        expect(result.error!.code, 'delivery');
        expect(transfers.leased, greaterThan(0));
        expect(transfers.released, transfers.leased);
        expect(transfers.liveBytes, 0);
        // A completed read after the failed sink checks reuse with real leases.
        final next = analyzer.analyzeDocument(
          pages: source,
          options: podoco.AnalysisOptions(
            profile: analyzer.profile,
            formulaScope: podoco.FormulaScope.none,
          ),
          onUpdate: (_) async {},
        );
        expect((await next.done).status, podoco.CompletionStatus.completed);
        await next.dispose();
        expect(transfers.released, transfers.leased);
        expect(transfers.liveBytes, 0);
      });
      test(
        'formula-prefix cancellation drains actual renderer ownership',
        () async {
          final transfers = AnalysisImageTransfers();
          final source = await PdfAnalysisSource.create(
            pdf,
            transfers: transfers,
          );
          final first = Completer<void>();
          late podoco.AnalysisJob job;
          job = analyzer.analyzeDocument(
            pages: source,
            options: options(),
            onUpdate: (u) async {
              if (u is podoco.FormulaFinished && !first.isCompleted) {
                first.complete();
                job.cancel();
              }
            },
          );
          final result = await job.done;
          await job.dispose();
          expect(first.isCompleted, isTrue);
          expect(result.status, podoco.CompletionStatus.cancelled);
          expect(transfers.released, transfers.leased);
          expect(transfers.liveBytes, 0);
        },
        skip: formulaPath == null || actualPdf == null
            ? 'Requires real formula corpus'
            : false,
      );
    },
    skip: layoutPath == null
        ? 'Requires explicit native model qualification'
        : false,
  );
}

class DelayedSource implements podoco.PageSource {
  DelayedSource(this.source);
  final podoco.PageSource source;
  final rendered = Completer<void>(), resume = Completer<void>();
  @override
  podoco.DocumentRef get document => source.document;
  @override
  List<podoco.PageDescriptor> get pages => source.pages;
  @override
  Future<podoco.PageInput> loadPage(podoco.PageRequest request) async {
    final input = await source.loadPage(request);
    rendered.complete();
    await resume.future;
    return input;
  }
}
