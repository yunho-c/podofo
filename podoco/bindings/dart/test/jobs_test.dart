import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:podoco/podoco.dart';
import 'package:test/test.dart';

class Fixtures implements PageSource {
  @override
  final document = DocumentRef('png-sequence', '1');
  late final List<PageDescriptor> _pages = [
    for (var i = 0; i < 3; i++)
      PageDescriptor(
        PageKey(document, i),
        PageSpace([640.0, 800.0, 257.0][i], [800.0, 1000.0, 193.0][i]),
      ),
  ];
  @override
  List<PageDescriptor> get pages => _pages;
  final bool leased;
  int rendered = 0, released = 0;
  Fixtures({this.leased = false});
  @override
  Future<PageInput> loadPage(PageRequest request) async {
    rendered++;
    final name = ['columns', 'equations', 'raster'][request.page.key.pageIndex];
    final bytes = await File(
      '${Platform.environment['PODOCO_M4_FIXTURES']}/$name.rgba',
    ).readAsBytes();
    final descriptor = ImageDescriptor(
      width: request.page.space.width.toInt(),
      height: request.page.space.height.toInt(),
      rowStride: request.page.space.width.toInt() * 4,
      format: PixelFormat.rgba8,
      alpha: AlphaMode.straight,
    );
    final PageImage image;
    if (leased) {
      final memory = calloc<Uint8>(bytes.length);
      memory.asTypedList(bytes.length).setAll(0, bytes);
      try {
        image = PageImage.importNative(
          descriptor: descriptor,
          pointer: memory,
          initializedBytes: bytes.length,
          retainedBytes: bytes.length,
          byteBudget: request.byteBudget,
          onRelease: () {
            released++;
            calloc.free(memory);
          },
        );
      } catch (_) {
        calloc.free(memory);
        rethrow;
      }
    } else {
      image = PageImage.copy(
        descriptor: descriptor,
        bytes: bytes,
        byteBudget: request.byteBudget,
      );
    }
    return PageInput(
      page: request.page,
      image: image,
      pixelToPage: Affine.identity(),
      renderProfile: 'png-pixel-space-v1',
    );
  }
}

Future<void> until(bool Function() condition) async {
  final end = DateTime.now().add(const Duration(seconds: 10));
  while (!condition()) {
    if (DateTime.now().isAfter(end)) throw StateError('Condition deadline');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  final path = Platform.environment['PODOCO_M2_BUNDLE'];
  final enabled =
      path != null &&
      Platform.environment['PODOCO_M4_FIXTURES'] != null &&
      coreMlAvailable;
  group(
    'native document SDK',
    () {
      late Analyzer analyzer;
      late AnalysisOptions options;
      late List<Object?> expected;
      setUpAll(() async {
        final bundle = await ModelBundle.verify(path!);
        analyzer = await Analyzer.open(
          bundle,
          options: AnalyzerOptions(
            computePolicy: ComputePolicy.cpuAndNeuralEngine,
            limits: ResourceLimits(
              queuedJobs: 2,
              inputBytes: 4000000,
              pendingUpdates: 2,
              resultBytes: 500000,
              maxUpdateBytes: 250000,
              tensorBytes: 96000000,
              decoderCacheBytes: 1,
            ),
          ),
        );
        options = AnalysisOptions(
          profile: bundle.profile,
          formulaScope: FormulaScope.none,
        );
        expected = File(Platform.environment['PODOCO_M4_REFERENCE']!)
            .readAsLinesSync()
            .map(jsonDecode)
            .toList();
        expect(analyzer.capabilities.layout, isTrue);
        expect(analyzer.capabilities.formulaRecognition, isFalse);
      });
      tearDownAll(() async {
        await analyzer.dispose();
        await analyzer.dispose();
        expect(nativeLiveHandles, 0);
      });
      test('real copied and leased pages equal Rust; done needs no progress subscriber', () async {
        for (final leased in [false, true]) {
          final source = Fixtures(leased: leased), updates = <AnalysisUpdate>[];
          final job = analyzer.analyzeDocument(
            pages: source,
            options: options,
            onUpdate: (u) async {
              updates.add(u);
            },
          );
          expect(job.id, isNotEmpty);
          final outcome = await job.done;
          expect(outcome.status, CompletionStatus.completed);
          expect(updates.map((u) => u.sequence), [0, 1, 2, 3, 4, 5, 6]);
          expect(outcome.delivered.updatesAcknowledged, 7);
          expect(outcome.delivered.pagesFinished, 3);
          expect(outcome.delivered.documentFinished, isTrue);
          expect(outcome.progress.pendingResultBytes, 0);
          for (var i = 0; i < 3; i++) {
            expect(
              (updates[i * 2].toJson()['payload'] as Map)['page'],
              expected[i],
            );
            expect(
              (updates[i * 2 + 1].toJson()['payload'] as Map)['page'],
              expected[i],
            );
          }
          if (leased) expect(source.released, 3);
          await job.dispose();
          await job.dispose();
          expect(nativeLiveHandles, 1);
        }
      });
      test('unsupported formula request fails before source rendering', () {
        final source = Fixtures();
        expect(
          () => analyzer.analyzeDocument(
            pages: source,
            options: AnalysisOptions(profile: options.profile),
            onUpdate: (_) async {},
          ),
          throwsA(
            isA<PodocoException>().having(
              (e) => e.code,
              'code',
              'unsupported_capability',
            ),
          ),
        );
        expect(source.rendered, 0);
        expect(nativeLiveHandles, 1);
      });
      test(
        'slow sink bounds updates while control releases leases and cancels',
        () async {
          final source = Fixtures(leased: true),
              entered = Completer<void>(),
              resume = Completer<void>();
          var first = true;
          final job = analyzer.analyzeDocument(
            pages: source,
            options: options,
            onUpdate: (u) async {
              if (first) {
                first = false;
                entered.complete();
                await resume.future;
              }
            },
          );
          await entered.future;
          await until(
            () =>
                job.latestProgress?.processed.pagesFinished == 2 &&
                source.released == 2,
          );
          expect(job.latestProgress!.pendingUpdates, lessThanOrEqualTo(2));
          expect(
            job.latestProgress!.pendingResultBytes,
            lessThanOrEqualTo(500000),
          );
          job.cancel();
          expect(source.released, 2);
          resume.complete();
          final outcome = await job.done;
          expect(outcome.status, CompletionStatus.cancelled);
          expect(outcome.delivered.pagesFinished, 0);
          expect(outcome.delivered.documentFinished, isTrue);
          expect(nativeLiveHandles, 1);
        },
      );
      test(
        'late render is released and done waits for its async callback',
        () async {
          final source = Fixtures(leased: true),
              entered = Completer<void>(),
              stopped = Completer<void>(),
              resume = Completer<void>();
          final job = analyzer.analyzePage(
            page: source.pages.first,
            options: options,
            loadPage: (r) async {
              entered.complete();
              await r.cancellation.cancelled;
              stopped.complete();
              await resume.future;
              return source.loadPage(r);
            },
            onUpdate: (u) async {
              expect(u, isA<DocumentFinished>());
            },
          );
          var done = false;
          final completion = job.done.then((v) {
            done = true;
            return v;
          });
          await entered.future;
          final nextSource = Fixtures();
          final next = analyzer.analyzePage(
            page: nextSource.pages.first,
            options: options,
            loadPage: nextSource.loadPage,
            onUpdate: (_) async {},
          );
          job.cancel();
          await stopped.future;
          await until(() => job.latestProgress?.cancellationRequested == true);
          expect(job.latestProgress!.inputBytes, 4000000);
          expect(nextSource.rendered, 0);
          expect(done, isFalse);
          resume.complete();
          expect((await completion).status, CompletionStatus.cancelled);
          expect(source.released, 1);
          expect((await next.done).status, CompletionStatus.completed);
          expect(nativeLiveHandles, 1);
        },
      );
      test(
        'terminal sink failure preserves processing and delivery distinction',
        () async {
          final job = analyzer.analyzePage(
            page: Fixtures().pages.first,
            options: options,
            loadPage: Fixtures().loadPage,
            onUpdate: (u) async {
              if (u is DocumentFinished) throw StateError('persistence failed');
            },
          );
          final outcome = await job.done;
          expect(outcome.summary.status, CompletionStatus.completed);
          expect(outcome.status, CompletionStatus.failed);
          expect(outcome.error!.code, 'delivery');
          expect(outcome.delivered.documentFinished, isFalse);
          expect(nativeLiveHandles, 1);
        },
      );
      test(
        'FIFO admission and queued cancellation never invoke a queued renderer',
        () async {
          final firstSource = Fixtures(),
              entered = Completer<void>(),
              resume = Completer<void>();
          final first = analyzer.analyzePage(
            page: firstSource.pages.first,
            options: options,
            loadPage: (r) async {
              entered.complete();
              await resume.future;
              return firstSource.loadPage(r);
            },
            onUpdate: (_) async {},
          );
          await entered.future;
          var rendered = 0;
          final second = analyzer.analyzePage(
            page: firstSource.pages.first,
            options: options,
            loadPage: (r) async {
              rendered++;
              return firstSource.loadPage(r);
            },
            onUpdate: (_) async {},
          );
          final third = analyzer.analyzePage(
            page: firstSource.pages.first,
            options: options,
            loadPage: firstSource.loadPage,
            onUpdate: (_) async {},
          );
          expect(
            () => analyzer.analyzePage(
              page: firstSource.pages.first,
              options: options,
              loadPage: firstSource.loadPage,
              onUpdate: (_) async {},
            ),
            throwsA(
              isA<PodocoException>().having(
                (e) => e.code,
                'code',
                'limit_exceeded',
              ),
            ),
          );
          second.cancel();
          resume.complete();
          expect((await first.done).status, CompletionStatus.completed);
          expect((await second.done).status, CompletionStatus.cancelled);
          expect((await third.done).status, CompletionStatus.completed);
          expect(rendered, 0);
          expect({first.id, second.id, third.id}.length, 3);
          expect(nativeLiveHandles, 1);
        },
      );
      test(
        'analyzer disposal drains cooperative sources and rejects future jobs',
        () async {
          final bundle = await ModelBundle.verify(path!);
          final other = await Analyzer.open(bundle, options: analyzer.options);
          final source = Fixtures(), entered = Completer<void>();
          final job = other.analyzePage(
            page: source.pages.first,
            options: options,
            loadPage: (r) async {
              entered.complete();
              await r.cancellation.cancelled;
              return source.loadPage(r);
            },
            onUpdate: (_) async {},
          );
          await entered.future;
          final closing = other.dispose();
          expect((await job.done).status, CompletionStatus.cancelled);
          await closing;
          await other.dispose();
          expect(
            () => other.analyzeDocument(
              pages: source,
              options: options,
              onUpdate: (_) async {},
            ),
            throwsStateError,
          );
          expect(nativeLiveHandles, 1);
        },
      );
      test(
        'callback waits fail without deadlocking; cancellation remains safe',
        () async {
          late AnalysisJob job;
          job = analyzer.analyzePage(
            page: Fixtures().pages.first,
            options: options,
            loadPage: Fixtures().loadPage,
            onUpdate: (u) async {
              expect(() => job.done, throwsStateError);
              expect(() => analyzer.dispose(), throwsStateError);
            },
          );
          expect((await job.done).status, CompletionStatus.completed);
          expect(nativeLiveHandles, 1);
        },
      );
    },
    skip: enabled ? false : 'Set explicit M2 bundle, M4 fixtures/reference, and use a Core ML native artifact.',
    timeout: const Timeout(Duration(minutes: 1)),
  );
}
