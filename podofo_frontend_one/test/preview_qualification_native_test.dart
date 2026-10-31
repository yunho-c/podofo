import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:podoco/podoco.dart' as podoco;
import 'package:podoco_flutter/podoco_flutter.dart';
import 'package:podofo_one/src/analysis/analysis_coordinator.dart';
import 'package:podofo_one/src/analysis/analysis_engine.dart';
import 'package:podofo_one/src/analysis/analysis_store.dart';
import 'package:podofo_one/src/analysis/pdf_analysis_source.dart';
import 'package:podofo_one/src/analysis/pdf_image_input.dart';
import 'package:podofo_one/src/analysis/preview_layout_repository.dart';
import 'package:podofo_one/src/analysis/preview_layout_store.dart';
import 'package:podofo_one/src/previews/link_target.dart';
import 'package:podofo_one/src/services/pdf_session.dart';
import 'package:podofo_one/src/workers/link_preview_worker.dart';

import 'support/file_access_mock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final run = Platform.environment['TARGET_PREVIEW_QUALIFICATION_RUN'];
  test(
    'measure each cache/model state and drain 100 native hover/cancel cycles',
    () async {
      installFileAccessMock();
      final out = Directory('build/target-preview-m5/performance-$run');
      if (await out.exists()) throw StateError('Use a fresh run id');
      await out.create(recursive: true);
      await pdfrxInitialize(tmpPath: out.absolute.path);
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
      final links = await session.lease.document.pages.first.loadLinks();
      final link = links[2];
      final request = LinkPreviewRequest(
        session: session,
        sourcePage: 1,
        annotationIndex: 2,
        sourceRects: link.rects,
        destination: link.dest!,
        pixelRatio: 2,
      );
      final records = <Map<String, Object?>>[],
          cycles = <Map<String, Object?>>[];
      final host = <String, Object?>{
        'os': Platform.operatingSystemVersion,
        'dart': Platform.version,
        'cpu': (await Process.run('sysctl', [
          '-n',
          'machdep.cpu.brand_string',
        ])).stdout.toString().trim(),
        'memory_bytes': (await Process.run('sysctl', [
          '-n',
          'hw.memsize',
        ])).stdout.toString().trim(),
      };
      _Harness? active;
      var finished = false;
      try {
        expect(podoco.nativeLiveHandles, 0);
        // Cold means no app model/cache/text/image state. The process, filesystem,
        // Core ML compilation cache and OS page cache are not flushed.
        for (var i = 0; i < 20; i++) {
          active = _Harness(Directory('${out.path}/cold-$i'));
          records.add(await active.hover(request, 'cold_preparation', i));
          expect(active.opens, 1);
          expect(active.jobs, 1);
          await active.close();
          expect(podoco.nativeLiveHandles, 0);
        }
        // A new worker/coordinator each time: only the persisted layout survives.
        for (var i = 0; i < 20; i++) {
          active = _Harness(Directory('${out.path}/cold-0'));
          records.add(await active.hover(request, 'disk_layout', i));
          expect(active.opens, 0);
          expect(active.jobs, 0);
          await active.close();
          expect(podoco.nativeLiveHandles, 0);
        }
        active = _Harness(Directory('${out.path}/warm'));
        await active.hover(request, 'warmup', 0);
        await active.idle();
        final baselineHandles = podoco.nativeLiveHandles;
        expect(baselineHandles, greaterThan(0));
        for (var i = 0; i < 20; i++) {
          await active.clearDerivedPage();
          final before = active.jobs;
          records.add(await active.hover(request, 'warm_analysis', i));
          await active.idle();
          expect(active.jobs, before + 1);
          expect(active.opens, 1);
        }
        // The current architecture caches decoded images and text but still reads
        // layout provenance from disk on each hover. Do not call this disk-free.
        for (var i = 0; i < 30; i++) {
          final jobs = active.jobs;
          final renders = active.contextRenders;
          records.add(await active.hover(request, 'decoded_image_and_text', i));
          expect(active.jobs, jobs);
          expect(active.contextRenders, renders);
        }
        for (var i = 0; i < 100; i++) {
          final phase = i ~/ 25;
          var refinements = 0;
          if (phase == 3) {
            final index = i % 6, selected = links[index];
            await active.hover(
              LinkPreviewRequest(
                session: session,
                sourcePage: 1,
                annotationIndex: index,
                sourceRects: selected.rects,
                destination: selected.dest!,
                pixelRatio: [1.0, 1.5, 2.0][(i ~/ 6) % 3],
              ),
              'stress_complete',
              i,
              expectedLabel: [
                'Reference [23]',
                'Reference [24]',
                'Figure 4',
                'Table 2',
                'Equation (7)',
                'Section 2.1',
              ][index],
            );
          } else {
            if (phase == 2) await active.clearDerivedPage();
            final loaded = Completer<void>(), release = Completer<void>();
            if (phase == 2) {
              active.inputGate = () async {
                loaded.complete();
                await release.future;
              };
            }
            final pending = active.worker.load(
              session,
              link.dest!,
              pixelRatio: 2,
              request: request,
              repository: active.repository,
              onRefinement: (image, target) {
                refinements++;
                image.dispose();
              },
            );
            try {
              if (phase == 0) active.worker.cancel();
              (await pending)?.dispose();
              if (phase == 2) {
                await loaded.future.timeout(const Duration(seconds: 20));
                expect(active.transfers.liveBytes, greaterThan(0));
              }
              active.worker.cancel();
            } finally {
              release.complete();
              active.inputGate = null;
            }
            await active.idle();
            expect(refinements, 0, reason: 'Cancelled hover must not refine');
          }
          await active.idle();
          final disk = await active.diskBytes();
          expect(
            active.worker.cache.bytes,
            lessThanOrEqualTo(active.worker.cache.maxBytes),
          );
          expect(
            active.worker.cache.length,
            lessThanOrEqualTo(active.worker.cache.maxEntries),
          );
          expect(
            active.worker.context.bytes,
            lessThanOrEqualTo(active.worker.context.maxBytes),
          );
          expect(
            active.worker.context.length,
            lessThanOrEqualTo(active.worker.context.maxPages),
          );
          expect(disk, lessThanOrEqualTo(active.store.maxBytes));
          expect(active.transfers.liveBytes, 0);
          expect(active.transfers.leased, active.transfers.released);
          expect(podoco.nativeLiveHandles, baselineHandles);
          cycles.add({
            'iteration': i,
            'phase': [
              'immediate_cancel',
              'context_cancel',
              'input_lease_cancel',
              'complete',
            ][phase],
            'decoded_bytes': active.worker.cache.bytes,
            'decoded_entries': active.worker.cache.length,
            'text_bytes': active.worker.context.bytes,
            'text_pages': active.worker.context.length,
            'layout_disk_bytes': disk,
            'native_handles': podoco.nativeLiveHandles,
            'renderer_live_bytes': active.transfers.liveBytes,
          });
        }
        expect(session.revision, 0);
        expect(session.navigationHistory.previous, isNull);
        await active.close();
        expect(active.worker.cache.bytes, 0);
        expect(active.worker.context.bytes, 0);
        expect(active.transfers.liveBytes, 0);
        expect(podoco.nativeLiveHandles, 0);
        final summaries = _summaries(records);
        // A regression should fail the gate while still retaining all samples.
        expect(
          (summaries['decoded_image_and_text'] as Map)['semantic_p95_us'],
          lessThanOrEqualTo(150000),
        );
        expect(
          (summaries['disk_layout'] as Map)['semantic_p95_us'],
          lessThanOrEqualTo(150000),
        );
        finished = true;
      } finally {
        await active?.close();
        await session.close();
        messenger.setMockMethodCallHandler(NativeModelResources.channel, null);
        await PdfrxEntryFunctions.instance.stopBackgroundWorker();
        await File('${out.path}/results.json').writeAsString(
          const JsonEncoder.withIndent('  ').convert({
            'passed': finished,
            'resolver_version': linkResolverVersion,
            'host': host,
            'pixel_ratio': 2,
            'fixture': 'linked_objects.pdf / Figure 4',
            'timing_boundary': 'worker.load entry to contextual future / semantic callback; excludes hover debounce and capture/assertions',
            'cold_boundary': 'fresh worker/coordinator/layout directory; PDF already open, same process, OS and Core ML caches retained',
            'memory_boundary': 'decoded image and text hits; layout provenance is still read from disk',
            'summaries': _summaries(records),
            'samples': records,
            'cycles': cycles,
            'native_handles_after_close': podoco.nativeLiveHandles,
          }),
        );
      }
    },
    skip: run == null
        ? 'Set TARGET_PREVIEW_QUALIFICATION_RUN to a fresh suffix'
        : false,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

Map<String, Object> _summaries(List<Map<String, Object?>> records) => {
  for (final mode in records.map((r) => r['mode'] as String).toSet())
    mode: {
      'count': records.where((r) => r['mode'] == mode).length,
      for (final field in ['context', 'semantic'])
        for (final percentile in [50, 95])
          '${field}_p${percentile}_us': _percentile(
            records
                .where((r) => r['mode'] == mode)
                .map((r) => r['${field}_us'] as int)
                .toList(),
            percentile,
          ),
    },
};

int _percentile(List<int> values, int percentile) {
  values.sort();
  return values[math.max(0, (values.length * percentile / 100).ceil() - 1)];
}

class _Harness {
  _Harness(this.root) {
    worker = LinkPreviewWorker(
      render: (pdf, dest, ratio, cancellation) {
        contextRenders++;
        return renderLinkPreview(pdf, dest, ratio, cancellation);
      },
    );
    store = PreviewLayoutStore(Directory('${root.path}/layout'));
    coordinator = AnalysisCoordinator(
      store: store,
      manualStore: AnalysisStore(Directory('${root.path}/manual')),
      manualEngine: () => null,
      openLayout: () async {
        opens++;
        final engine = await NativeAnalysisEngine.openBundledLayout((_) {});
        expect(engine.recognizesFormulas, false);
        expect(engine.manifests, hasLength(1));
        return _ObservedEngine(engine, () => jobs++);
      },
      inspectProfile: () => NativeAnalysisEngine.previewProfile(null),
      createSource: (session) async => _Source(
        await PdfAnalysisSource.create(session, transfers: transfers),
        () async {
          await inputGate?.call();
        },
      ),
    );
    repository = PreviewLayoutRepository.onDemand(coordinator);
  }
  final Directory root;
  late final LinkPreviewWorker worker;
  late final PreviewLayoutStore store;
  late final AnalysisCoordinator coordinator;
  late final PreviewLayoutRepository repository;
  final transfers = AnalysisImageTransfers();
  int opens = 0, jobs = 0, contextRenders = 0;
  Future<void> Function()? inputGate;

  Future<Map<String, Object?>> hover(
    LinkPreviewRequest request,
    String mode,
    int iteration, {
    String expectedLabel = 'Figure 4',
  }) async {
    final timer = Stopwatch()..start();
    final semantic = Completer<int>();
    final beforeOpens = opens,
        beforeJobs = jobs,
        beforeRenders = contextRenders;
    final context = await worker.load(
      request.session,
      request.destination,
      pixelRatio: request.pixelRatio,
      request: request,
      repository: repository,
      onRefinement: (image, target) {
        final elapsed = timer.elapsedMicroseconds;
        image.dispose();
        if (target.label != expectedLabel) {
          semantic.completeError(
            StateError('Unexpected target: ${target.label}'),
          );
        } else {
          semantic.complete(elapsed);
        }
      },
    );
    final contextMicros = timer.elapsedMicroseconds;
    expect(context, isNotNull);
    context?.dispose();
    final semanticMicros = await semantic.future.timeout(
      const Duration(seconds: 30),
    );
    return {
      'mode': mode,
      'iteration': iteration,
      'context_us': contextMicros,
      'semantic_us': semanticMicros,
      'model_opens': opens - beforeOpens,
      'analysis_jobs': jobs - beforeJobs,
      'context_renders': contextRenders - beforeRenders,
    };
  }

  Future<void> idle() async {
    // Admission/text extraction can still be unwinding after immediate cancel.
    // Yield before checking the native lane and its renderer ownership.
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final timer = Stopwatch()..start();
    while (coordinator.activePreviewJobs != 0 ||
        coordinator.pendingPreviewPages != 0 ||
        transfers.liveBytes != 0) {
      if (timer.elapsed > const Duration(seconds: 20)) {
        throw StateError('Native lane did not drain');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  Future<void> clearDerivedPage() async {
    worker.reset();
    await idle();
    if (await store.directory.exists()) {
      await for (final f in store.directory.list()) {
        if (f is File && f.path.endsWith('.json')) await f.delete();
      }
    }
  }

  Future<int> diskBytes() async {
    var bytes = 0;
    if (await store.directory.exists()) {
      await for (final f in store.directory.list()) {
        if (f is File) bytes += await f.length();
      }
    }
    return bytes;
  }

  Future<void> close() async {
    worker.dispose();
    await coordinator.close();
  }
}

class _Source implements podoco.PageSource {
  _Source(this.source, this.gate);
  final podoco.PageSource source;
  final Future<void> Function() gate;
  @override
  podoco.DocumentRef get document => source.document;
  @override
  List<podoco.PageDescriptor> get pages => source.pages;
  @override
  Future<podoco.PageInput> loadPage(podoco.PageRequest request) async {
    final input = await source.loadPage(request);
    await gate();
    return input;
  }
}

class _ObservedEngine implements AnalysisEngine {
  _ObservedEngine(this.delegate, this.onJob);
  final AnalysisEngine delegate;
  final void Function() onJob;
  @override
  String get profile => delegate.profile;
  @override
  List<String> get manifests => delegate.manifests;
  @override
  podoco.ComputePolicy get computePolicy => delegate.computePolicy;
  @override
  bool get recognizesFormulas => delegate.recognizesFormulas;
  @override
  DocumentAnalysisJob analyze(
    podoco.PageSource source,
    Future<void> Function(podoco.AnalysisUpdate) sink,
  ) => throw StateError('Hover must not analyze a document');
  @override
  DocumentAnalysisJob analyzePage(
    podoco.PageSource source,
    int index,
    Future<void> Function(podoco.AnalysisUpdate) sink, {
    podoco.FormulaScope formulaScope = podoco.FormulaScope.none,
  }) {
    expect(formulaScope, podoco.FormulaScope.none);
    onJob();
    return delegate.analyzePage(
      source,
      index,
      sink,
      formulaScope: formulaScope,
    );
  }

  @override
  Future<void> close() => delegate.close();
}
