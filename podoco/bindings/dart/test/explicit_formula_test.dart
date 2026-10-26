import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:podoco/podoco.dart';
import 'package:test/test.dart';

void main() {
  final page = PageDescriptor(
    PageKey(DocumentRef('crop-tests', '1'), 7),
    PageSpace(100, 100),
  );
  test('explicit crop geometry and serialized completion validate independently of native models', () {
    final crop = FormulaCrop(
      page: page,
      regionId: 23,
      bounds: PageRect(10, 20, 30, 40),
      displayKind: FormulaDisplayKind.inline,
    );
    expect(FormulaCrop.fromJson(crop.toJson()), crop);
    expect(
      () => FormulaCrop(
        page: page,
        regionId: -1,
        bounds: crop.bounds,
        displayKind: crop.displayKind,
      ),
      throwsArgumentError,
    );
    expect(
      () => FormulaCrop(
        page: page,
        regionId: 1,
        bounds: PageRect(0, 0, 101, 20),
        displayKind: crop.displayKind,
      ),
      throwsArgumentError,
    );
    final json = <String, Object?>{
      'analysis_id': 'crop-test',
      'crop': crop.toJson(),
      'status': 'cancelled',
      'outcome': null,
      'error': null,
      'progress': {
        'phase': 'finished',
        'cancellation_requested': true,
        'input_bytes': 0,
        'peak_input_bytes': 16,
        'peak_result_bytes': 0,
      },
    };
    final result = FormulaJobOutcome.fromJson(json);
    expect(result.status, CompletionStatus.cancelled);
    expect(
      () => result.toJson()['status'] = 'completed',
      throwsUnsupportedError,
    );
    expect(
      () => FormulaJobOutcome.fromJson({...json, 'status': 'completed'}),
      throwsFormatException,
    );
    expect(
      () => FormulaJobOutcome.fromJson({
        ...json,
        'progress': {...json['progress'] as Map, 'input_bytes': 16},
      }),
      throwsFormatException,
    );
  });

  final reference = Platform.environment['PODOCO_M6_REFERENCE'];
  final layoutPath = Platform.environment['PODOCO_M2_BUNDLE'];
  final formulaPath = Platform.environment['PODOCO_M6_BUNDLE'];
  final enabled =
      reference != null &&
      layoutPath != null &&
      formulaPath != null &&
      coreMlAvailable;
  group(
    'native explicit crop jobs',
    () {
      late Analyzer analyzer;
      late ModelBundle layout;
      late FormulaBundle formula;
      late List<Map<String, Object?>> images, expected;
      final report = <Map<String, Object?>>[];
      AnalyzerOptions limits() => AnalyzerOptions(
        computePolicy: ComputePolicy.cpuAndNeuralEngine,
        limits: ResourceLimits(
          queuedJobs: 2,
          inputBytes: 16 * 1024 * 1024,
          pendingUpdates: 2,
          resultBytes: 4 * 1024 * 1024,
          maxUpdateBytes: 2 * 1024 * 1024,
          tensorBytes: 128 * 1024 * 1024,
          decoderCacheBytes: 48 * 1024 * 1024,
        ),
      );
      FormulaCrop crop(Map<String, Object?> row, {int index = 7}) =>
          FormulaCrop(
            page: PageDescriptor(
              PageKey(DocumentRef('explicit-crop-reference', '1'), index),
              PageSpace(
                (row['width'] as int) + 40.0,
                (row['height'] as int) + 60.0,
              ),
            ),
            regionId: index,
            bounds: PageRect(
              17,
              23,
              17.0 + (row['width'] as int),
              23.0 + (row['height'] as int),
            ),
            displayKind: index.isEven
                ? FormulaDisplayKind.displayed
                : FormulaDisplayKind.inline,
          );
      Future<PageInput> render(
        Map<String, Object?> row,
        FormulaRequest request, {
        void Function()? release,
      }) async {
        final bytes = await File('$reference/${row['id']}.rgba').readAsBytes();
        final descriptor = ImageDescriptor(
          width: row['width'] as int,
          height: row['height'] as int,
          rowStride: (row['width'] as int) * 4,
          format: PixelFormat.rgba8,
          alpha: AlphaMode.straight,
        );
        final PageImage image;
        if (release == null) {
          image = PageImage.copy(
            descriptor: descriptor,
            bytes: bytes,
            byteBudget: request.byteBudget,
          );
        } else {
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
                calloc.free(memory);
                release();
              },
            );
          } catch (_) {
            calloc.free(memory);
            rethrow;
          }
        }
        return PageInput(
          page: request.crop.page,
          image: image,
          pixelToPage: Affine([1, 0, 0, 1, 17, 23]),
          renderProfile: 'm6-original-crop-offset-v1',
        );
      }

      setUpAll(() async {
        layout = await ModelBundle.verify(layoutPath!);
        formula = await FormulaBundle.verify(formulaPath!);
        final data = jsonDecode(
          await File('$reference/reference.json').readAsString(),
        ) as Map;
        images = (data['images'] as List)
            .map((e) => Map<String, Object?>.from(e as Map))
            .toList();
        expected = (data['texts'] as List)
            .map((e) => Map<String, Object?>.from(e as Map))
            .where((e) => e['run'] == '02-cpu-ne')
            .toList();
        analyzer = await Analyzer.open(
          layout,
          formulaBundle: formula,
          options: limits(),
        );
      });
      tearDownAll(() async {
        await analyzer.dispose();
        expect(nativeLiveHandles, 0);
        if (Platform.environment['PODOCO_CROP_OUTPUT'] case final path?) {
          await File(path).writeAsString(
            '${jsonEncode({'compared': report.length, 'outcomes': report, 'native_handles_after': nativeLiveHandles})}\n',
          );
        }
      });
      test('copied and leased crop-only rasters preserve full page context and deployed reference text', () async {
        var released = 0;
        final baseline = nativeLiveHandles;
        for (final (index, row) in images.take(16).indexed) {
          for (final leased in [false, true]) {
            final context = crop(row, index: index);
            final job = analyzer.recognizeFormula(
              crop: context,
              loadCrop: (r) => render(
                row,
                r,
                release: leased
                    ? () {
                        released++;
                      }
                    : null,
              ),
            );
            final outcome = await job.done;
            expect(outcome.crop, context);
            expect(outcome.analysisId, job.id);
            expect(outcome.status, CompletionStatus.completed);
            final recognized = (outcome.outcome as FormulaRecognized).formula;
            expect(
              recognized.latex,
              expected.firstWhere((e) => e['id'] == row['id'])['latex'],
            );
            expect(recognized.displayKind, context.displayKind);
            expect(outcome.progress.inputBytes, 0);
            expect(outcome.progress.peakInputBytes, limits().limits.inputBytes);
            expect(nativeLiveHandles, baseline);
            report.add({
              'id': row['id'],
              'leased': leased,
              'result': outcome.toJson(),
            });
          }
        }
        expect(released, 16);
      });
      test(
        'cancelled late leased crop drains before the next queued loader runs',
        () async {
          final entered = Completer<void>(), finish = Completer<void>();
          var released = 0;
          final first = analyzer.recognizeFormula(
            crop: crop(images.first),
            loadCrop: (request) async {
              final image = await render(
                images.first,
                request,
                release: () {
                  released++;
                },
              );
              entered.complete();
              await finish.future;
              return image;
            },
          );
          await entered.future;
          first.cancel();
          var firstDone = false;
          unawaited(
            first.done.then((_) {
              firstDone = true;
            }),
          );
          final next = analyzer.recognizeFormula(
            crop: crop(images[1]),
            loadCrop: (request) {
              expect(
                released,
                1,
                reason: 'The native lane must wait for foreign release acknowledgement',
              );
              return render(images[1], request);
            },
          );
          await Future<void>.delayed(const Duration(milliseconds: 30));
          expect(firstDone, false);
          expect(released, 0);
          finish.complete();
          expect((await first.done).status, CompletionStatus.cancelled);
          expect((await next.done).status, CompletionStatus.completed);
          expect(released, 1);
        },
      );
      test('crop queue overflow, queued cancellation, and callback wait rejection do not render', () async {
        final entered = Completer<void>(), gate = Completer<void>();
        final active = analyzer.recognizeFormula(
          crop: crop(images.first),
          loadCrop: (request) async {
            expect(analyzer.dispose, throwsStateError);
            entered.complete();
            await gate.future;
            return render(images.first, request);
          },
        );
        await entered.future;
        final queued = analyzer.recognizeFormula(
          crop: crop(images[1]),
          loadCrop: (_) => throw StateError('Cancelled queued renderer ran'),
        );
        queued.cancel();
        final after = analyzer.recognizeFormula(
          crop: crop(images[2]),
          loadCrop: (r) => render(images[2], r),
        );
        expect(
          () => analyzer.recognizeFormula(
            crop: crop(images[3]),
            loadCrop: (_) => throw StateError('Rejected renderer ran'),
          ),
          throwsA(
            isA<PodocoException>().having(
              (e) => e.code,
              'code',
              'limit_exceeded',
            ),
          ),
        );
        gate.complete();
        expect((await active.done).status, CompletionStatus.completed);
        expect((await queued.done).status, CompletionStatus.cancelled);
        expect((await after.done).status, CompletionStatus.completed);
      });
      test('source failure and incomplete raster coverage stay owned; decoder is reusable', () async {
        final failure = analyzer.recognizeFormula(
          crop: crop(images.first),
          loadCrop: (_) async => throw StateError('Render failed'),
        );
        expect((await failure.done).error!.code, 'page_source');
        final bad = analyzer.recognizeFormula(
          crop: crop(images.first),
          loadCrop: (request) async {
            final image = await render(images.first, request);
            return PageInput(
              page: image.page,
              image: image.image,
              pixelToPage: Affine.identity(),
              renderProfile: image.renderProfile,
            );
          },
        );
        expect((await bad.done).status, CompletionStatus.failed);
        expect(
          (await analyzer
                  .recognizeFormula(
                    crop: crop(images.first),
                    loadCrop: (r) => render(images.first, r),
                  )
                  .done)
              .status,
          CompletionStatus.completed,
        );
      });
      test('explicit token cap remains a truncated outcome and analyzer disposal drains crops', () async {
        final capped = await Analyzer.open(
          layout,
          formulaBundle: formula,
          formulaOptions: FormulaOptions(maxNewTokens: 1),
          options: limits(),
        );
        try {
          final job = capped.recognizeFormula(
            crop: crop(images.first),
            loadCrop: (r) => render(images.first, r),
          );
          final result = await job.done;
          expect(result.status, CompletionStatus.partial);
          expect(result.outcome, isA<FormulaTruncated>());
          final gate = Completer<void>(), entered = Completer<void>();
          final late = capped.recognizeFormula(
            crop: crop(images.first),
            loadCrop: (request) async {
              entered.complete();
              await gate.future;
              return render(images.first, request);
            },
          );
          await entered.future;
          final close = capped.dispose();
          gate.complete();
          await close;
          expect((await late.done).status, CompletionStatus.cancelled);
        } finally {
          await capped.dispose();
        }
      });
    },
    skip: enabled
        ? false
        : 'Requires explicit M2 bundle, M6 bundle/reference and Core ML build',
  );
}
