import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:podoco/podoco.dart';
import 'package:test/test.dart';

import '../example/document_layout.dart' show RawPages;

class FormulaPages extends RawPages {
  final bool leased;
  final int? failPage;
  int rendered = 0, released = 0;
  FormulaPages(super.root, super.data, {this.leased = false, this.failPage});

  @override
  Future<PageInput> loadPage(PageRequest request) async {
    if (request.page.key.pageIndex == failPage) {
      throw const PodocoException(
        'page_source',
        'Injected second-page failure',
      );
    }
    rendered++;
    if (!leased) return super.loadPage(request);
    final entry = entries[pages.indexWhere((p) => p.key == request.page.key)];
    final bytes = await File.fromUri(
      root.uri.resolve(entry['pixels'] as String),
    ).readAsBytes();
    final memory = calloc<Uint8>(bytes.length);
    memory.asTypedList(bytes.length).setAll(0, bytes);
    final PageImage image;
    try {
      image = PageImage.importNative(
        descriptor: ImageDescriptor.fromJson(
          Map<String, Object?>.from(entry['image'] as Map),
        ),
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
    return PageInput(
      page: request.page,
      image: image,
      pixelToPage: Affine.fromJson(entry['pixel_to_page']),
      renderProfile: entry['render_profile'] as String,
    );
  }
}

void main() {
  test('formula token cap rejects invalid values before native use', () {
    expect(FormulaOptions().maxNewTokens, 2048);
    for (final cap in [0, -1, 2049, 1 << 40]) {
      expect(() => FormulaOptions(maxNewTokens: cap), throwsArgumentError);
    }
  });
  final root = Platform.environment['PODOCO_M6_DOCUMENTS'];
  final formulaPath = Platform.environment['PODOCO_M6_BUNDLE'];
  final layoutPath = Platform.environment['PODOCO_M2_BUNDLE'];
  final enabled =
      root != null &&
      formulaPath != null &&
      layoutPath != null &&
      coreMlAvailable;
  group(
    'native formula document SDK',
    () {
      late Analyzer analyzer;
      late ModelBundle layout;
      late FormulaBundle formula;
      late Map<String, Object?> data;
      late List<Map<String, Object?>> expected;
      AnalyzerOptions limits({int tensor = 128 * 1024 * 1024}) =>
          AnalyzerOptions(
            computePolicy: ComputePolicy.cpuAndNeuralEngine,
            limits: ResourceLimits(
              queuedJobs: 2,
              inputBytes: 16 * 1024 * 1024,
              pendingUpdates: 2,
              resultBytes: 4 * 1024 * 1024,
              maxUpdateBytes: 2 * 1024 * 1024,
              tensorBytes: tensor,
              decoderCacheBytes: 48 * 1024 * 1024,
            ),
          );
      FormulaPages source({
        bool leased = false,
        int? failPage,
        int count = 2,
      }) => FormulaPages(
        Directory(root!),
        {...data, 'pages': (data['pages'] as List).take(count).toList()},
        leased: leased,
        failPage: failPage,
      );
      AnalysisOptions options(Analyzer a) =>
          AnalysisOptions(profile: a.profile);
      setUpAll(() async {
        layout = await ModelBundle.verify(layoutPath!);
        formula = await FormulaBundle.verify(formulaPath!);
        data = Map<String, Object?>.from(
          jsonDecode(File('$root/pages.json').readAsStringSync()) as Map,
        );
        expected = File('$root/rust.jsonl')
            .readAsLinesSync()
            .map(
              (line) => Map<String, Object?>.from(
                (jsonDecode(line) as Map)['payload'] as Map,
              ),
            )
            .where(
              (p) =>
                  p['type'] != 'document_finished' &&
                  ((p['page_key'] ?? (p['page'] as Map?)?['page']?['key'])
                          as Map)['page_index'] <
                      2,
            )
            .toList();
        analyzer = await Analyzer.open(
          layout,
          formulaBundle: formula,
          options: limits(),
        );
        expect(analyzer.capabilities.formulaRecognition, isTrue);
        expect(analyzer.modelManifests, [
          layout.manifestSha256,
          formula.manifestSha256,
        ]);
        expect(
          () => analyzer.modelManifests.add('changed'),
          throwsUnsupportedError,
        );
      });
      tearDownAll(() async {
        await analyzer.dispose();
        await analyzer.dispose();
        expect(nativeLiveHandles, 0);
      });
      test(
        'copied and leased multipage results equal Rust before completion',
        () async {
          for (final leased in [false, true]) {
            final pages = source(leased: leased),
                payloads = <Map<String, Object?>>[];
            var done = false, formulas = 0;
            final job = analyzer.analyzeDocument(
              pages: pages,
              options: options(analyzer),
              onUpdate: (u) async {
                if (u is FormulaFinished) {
                  expect(done, isFalse);
                  expect(u.outcome, isA<FormulaRecognized>());
                  formulas++;
                }
                if (u is! DocumentFinished) {
                  payloads.add(u.toJson()['payload'] as Map<String, Object?>);
                }
              },
            );
            final outcome = await job.done;
            done = true;
            expect(outcome.status, CompletionStatus.completed);
            expect(formulas, greaterThan(0));
            expect(payloads, expected);
            expect(outcome.delivered.formulasFinished, formulas);
            expect(outcome.delivered.pagesFinished, 2);
            expect(outcome.progress.inputBytes, 0);
            expect(outcome.progress.pendingResultBytes, 0);
            if (leased) expect(pages.released, pages.rendered);
            await job.dispose();
            expect(nativeLiveHandles, 1);
          }
        },
        timeout: const Timeout(Duration(minutes: 3)),
      );
      test('cancel after a delivered formula preserves usable prefix and releases pages', () async {
        final pages = source(leased: true), delivered = <FormulaFinished>[];
        late AnalysisJob job;
        job = analyzer.analyzeDocument(
          pages: pages,
          options: options(analyzer),
          onUpdate: (u) async {
            if (u is FormulaFinished) {
              delivered.add(u);
              job.cancel();
            }
          },
        );
        final outcome = await job.done;
        expect(outcome.status, CompletionStatus.cancelled);
        expect(delivered, hasLength(1));
        expect(
          (delivered.single.outcome as FormulaRecognized).formula.latex,
          isNotEmpty,
        );
        expect(outcome.delivered.formulasFinished, 1);
        expect(outcome.summary.counts.formulasPending, greaterThan(0));
        expect(pages.released, pages.rendered);
        expect(outcome.progress.inputBytes, 0);
        expect(outcome.delivered.documentFinished, isTrue);
        await job.dispose();
        // The next test reuses this same native decoder after interruption.
        expect(nativeLiveHandles, 1);
      });
      test('source failure retains completed formulas and decoder remains reusable', () async {
        final pages = source(leased: true, failPage: 1),
            firstPage = <Map<String, Object?>>[];
        final job = analyzer.analyzeDocument(
          pages: pages,
          options: options(analyzer),
          onUpdate: (u) async {
            if (u is PageFinished ||
                u is FormulaFinished ||
                u is PageLayoutReady) {
              firstPage.add(u.toJson()['payload'] as Map<String, Object?>);
            }
          },
        );
        final outcome = await job.done;
        expect(outcome.status, CompletionStatus.partial);
        expect(outcome.summary.counts.pagesFailed, 1);
        expect(outcome.delivered.pagesFinished, 1);
        expect(firstPage, expected.take(firstPage.length).toList());
        expect(pages.released, 1);
        await job.dispose();
      });
      test(
        'token-limited results are explicitly partial with cap in provenance',
        () async {
          final capped = await Analyzer.open(
            layout,
            formulaBundle: formula,
            formulaOptions: FormulaOptions(maxNewTokens: 1),
            options: limits(),
          );
          try {
            expect(capped.profile, endsWith('-cap1'));
            final outcomes = <FormulaOutcome>[];
            final job = capped.analyzeDocument(
              pages: source(count: 1),
              options: options(capped),
              onUpdate: (u) async {
                if (u is FormulaFinished) outcomes.add(u.outcome);
              },
            );
            final outcome = await job.done;
            expect(outcome.status, CompletionStatus.partial);
            expect(outcomes.whereType<FormulaTruncated>(), isNotEmpty);
            for (final truncated in outcomes.whereType<FormulaTruncated>()) {
              expect(truncated.provenance.profile, endsWith('-cap1'));
            }
            expect(outcome.summary.counts.formulasPending, 0);
            await job.dispose();
          } finally {
            await capped.dispose();
          }
          expect(nativeLiveHandles, 1);
        },
      );
      test(
        'combined budget rejects admission without leaking an analyzer',
        () async {
          await expectLater(
            Analyzer.open(
              layout,
              formulaBundle: formula,
              options: limits(tensor: 96 * 1024 * 1024 - 1),
            ),
            throwsA(
              isA<PodocoException>().having(
                (e) => e.code,
                'code',
                'limit_exceeded',
              ),
            ),
          );
          expect(nativeLiveHandles, 1);
        },
      );
    },
    skip: enabled ? false : 'Set explicit M2/M6 bundles and M6_DOCUMENTS for native qualification',
  );
}
