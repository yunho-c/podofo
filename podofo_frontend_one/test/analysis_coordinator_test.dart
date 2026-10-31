import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:podoco/podoco.dart' as podoco;
import 'package:podofo_one/src/analysis/analysis_coordinator.dart';
import 'package:podofo_one/src/analysis/analysis_engine.dart';
import 'package:podofo_one/src/analysis/analysis_store.dart';
import 'package:podofo_one/src/analysis/pdf_analysis_source.dart';
import 'package:podofo_one/src/analysis/preview_layout_store.dart';
import 'package:podofo_one/src/analysis/preview_layout_repository.dart';
import 'package:podofo_one/src/previews/link_target.dart';
import 'package:podofo_one/src/previews/pdf_link_context.dart';
import 'package:podofo_one/src/services/pdf_session.dart';

import 'analysis_native_test.dart' show ControlledEngine, ControlledJob;
import 'bundled_analysis_test.dart' show until;
import 'fixtures/analysis_fixture.dart';
import 'support/file_access_mock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporary;
  late PdfSession session;
  late PreviewLayoutStore store;
  late AnalysisStore manual;
  final profile = PreviewLayoutProfile(
    layoutManifest: fixtureManifest,
    layoutProfile: fixtureProfile,
    layoutAdapter: 'app-fixture',
    backend: 'test',
    computePolicy: podoco.ComputePolicy.cpuOnly,
  );
  setUpAll(() async {
    installFileAccessMock();
    temporary = await Directory.systemTemp.createTemp('preview-coordinator-');
    await pdfrxInitialize(tmpPath: temporary.path);
    session = await PdfSession.open(
      'test/fixtures/target_preview/linked_objects.pdf',
    );
  });
  setUp(() async {
    final root = await temporary.createTemp();
    store = PreviewLayoutStore(Directory('${root.path}/preview'));
    manual = AnalysisStore(Directory('${root.path}/manual'));
  });
  tearDownAll(() async {
    await session.close();
    await PdfrxEntryFunctions.instance.stopBackgroundWorker();
    await temporary.delete(recursive: true);
  });
  LinkPreviewRequest request([int page = 2]) => LinkPreviewRequest(
    session: session,
    sourcePage: 1,
    annotationIndex: page,
    sourceRects: [],
    destination: PdfDest(page, PdfDestCommand.fit, null),
    pixelRatio: 1,
  );
  AnalysisCoordinator coordinator(
    Future<AnalysisEngine> Function() open, {
    AnalysisEngine? Function()? warm,
    Future<PreviewLayoutProfile> Function()? inspect,
  }) => AnalysisCoordinator(
    store: store,
    manualStore: manual,
    manualEngine: warm ?? () => null,
    openLayout: open,
    inspectProfile: inspect ?? () async => profile,
  );

  test(
    'explicit FitR and unextractable source text never initialize analysis',
    () async {
      var opened = 0, inspected = 0;
      final shared = coordinator(
        () async {
          opened++;
          return _PageEngine();
        },
        inspect: () async {
          inspected++;
          return profile;
        },
      );
      final context = PdfLinkContext();
      try {
        for (final destination in [
          const PdfDest(2, PdfDestCommand.fitR, [100, 100, 200, 200]),
          const PdfDest(2, PdfDestCommand.fit, null),
        ]) {
          final prepared = await context.prepare(
            LinkPreviewRequest(
              session: session,
              sourcePage: 1,
              annotationIndex: 0,
              sourceRects: [],
              destination: destination,
              pixelRatio: 1,
            ),
            () => true,
            PreviewLayoutRepository.onDemand(shared),
          );
          expect(
            prepared!.resolution.tier,
            destination.command == PdfDestCommand.fitR
                ? LinkTargetTier.explicitArea
                : LinkTargetTier.unresolved,
          );
        }
        expect(opened, 0);
        expect(inspected, 0);
      } finally {
        context.clear();
        await shared.close();
      }
    },
  );

  test('identical page consumers coalesce; detaching one preserves shared work and cold cache reuse', () async {
    final engine = _PageEngine();
    var opens = 0;
    final shared = coordinator(() async {
      opens++;
      return engine;
    });
    try {
      final a = shared.request(request(), () => true);
      final b = shared.request(request(), () => true);
      await until(() => engine.calls.length == 1);
      a.cancel();
      expect(await a.result, isNull);
      expect(engine.calls.single.job.cancelled, false);
      await engine.calls.single.publish();
      expect((await b.result)!.page.page.key.pageIndex, 1);
      engine.calls.single.job.finish();
      await until(() => shared.activePreviewJobs == 0);
      final cached = await shared.request(request(), () => true).result;
      expect(cached, isNotNull);
      expect(engine.calls.length, 1);
      expect(opens, 1);
    } finally {
      await shared.close();
    }
    expect(engine.closeCount, 1);
    final restarted = coordinator(() async {
      fail('disk hit must not open an engine');
    });
    try {
      expect(await restarted.request(request(), () => true).result, isNotNull);
    } finally {
      await restarted.close();
    }
  });

  test('one active and only the latest pending page; every job requests no formulas', () async {
    final engine = _PageEngine(), shared = coordinator(() async => engine);
    try {
      final a = shared.request(request(1), () => true);
      await until(() => engine.calls.length == 1);
      final b = shared.request(request(2), () => true);
      final c = shared.request(request(3), () => true);
      expect(await b.result, isNull);
      expect(shared.activePreviewJobs, 1);
      expect(shared.pendingPreviewPages, 1);
      engine.calls.first.job.finish();
      expect(await a.result, isNull);
      await until(() => engine.calls.length == 2);
      expect(engine.calls.map((c) => c.page.pageIndex), [0, 2]);
      await engine.calls.last.publish();
      expect(await c.result, isNotNull);
      engine.calls.last.job.finish();
      expect(engine.scopes, everyElement(podoco.FormulaScope.none));
    } finally {
      engine.finish();
      await shared.close();
    }
  });

  test('manual priority drains preview, closes its engine, and serves layout updates without queuing inference', () async {
    final engine = _PageEngine(), shared = coordinator(() async => engine);
    try {
      final hover = shared.request(request(), () => true);
      await until(() => engine.calls.length == 1);
      var admitted = false;
      final admission = shared.beginExplicit().then((release) {
        admitted = true;
        return release;
      });
      expect(engine.calls.single.job.cancelled, true);
      await Future<void>.delayed(Duration.zero);
      expect(admitted, false);
      engine.calls.single.job.finish();
      final release = await admission;
      expect(engine.closeCount, 1);
      final joined = shared.request(request(), () => true);
      await shared.publishManual(
        AnalysisPageSnapshot.fromUpdate(
          analysisFixture(analysisDocumentRef(session), pageIndex: 1),
        ),
        () => true,
      );
      expect(await hover.result, isNotNull);
      expect(await joined.result, isNotNull);
      final unrelated = shared.request(request(3), () => true);
      await until(() => shared.pendingPreviewPages == 0);
      release();
      expect(await unrelated.result, isNull);
      expect(engine.calls.length, 1);
    } finally {
      engine.finish();
      await shared.close();
    }
  });

  test('warm manual engine is borrowed for layout only and remains owned by the controller', () async {
    final engine = _PageEngine();
    final shared = coordinator(() async {
      fail('warm engine should be reused');
    }, warm: () => engine);
    try {
      final hover = shared.request(request(), () => true);
      await until(() => engine.calls.length == 1);
      await engine.calls.single.publish();
      expect(await hover.result, isNotNull);
      engine.finish();
    } finally {
      engine.finish();
      await shared.close();
    }
    expect(engine.closeCount, 0);
    await engine.close();
  });

  test(
    'automatic initialization failure is latched until explicit retry',
    () async {
      final engine = _PageEngine();
      var attempts = 0;
      final shared = coordinator(() async {
        if (++attempts == 1) throw StateError('missing model');
        return engine;
      });
      try {
        expect(await shared.request(request(), () => true).result, isNull);
        expect(await shared.request(request(), () => true).result, isNull);
        expect(attempts, 1);
        expect(shared.automaticInitializationFailed, true);
        (await shared.beginExplicit())();
        final retry = shared.request(request(), () => true);
        await until(() => engine.calls.isNotEmpty);
        await engine.calls.single.publish();
        expect(await retry.result, isNotNull);
        engine.finish();
        expect(attempts, 2);
      } finally {
        engine.finish();
        await shared.close();
      }
    },
  );

  test('close waits for a late layout engine and releases it without starting a page', () async {
    final engine = _PageEngine(), gate = Completer<AnalysisEngine>();
    var opening = false;
    final shared = coordinator(() {
      opening = true;
      return gate.future;
    });
    final hover = shared.request(request(), () => true);
    await until(() => opening);
    final closing = shared.close();
    expect(await hover.result, isNull);
    gate.complete(engine);
    await closing;
    expect(engine.calls, isEmpty);
    expect(engine.closeCount, 1);
  });

  test(
    'explicit retry revalidates failed metadata with a warm manual engine',
    () async {
      final engine = _PageEngine();
      var inspections = 0;
      final shared = coordinator(
        () async => engine,
        warm: () => engine,
        inspect: () async {
          if (++inspections == 1) {
            throw StateError('temporary metadata failure');
          }
          return profile;
        },
      );
      try {
        expect(await shared.request(request(), () => true).result, isNull);
        expect(await shared.request(request(), () => true).result, isNull);
        expect(inspections, 1);
        (await shared.beginExplicit())();
        final retry = shared.request(request(), () => true);
        await until(() => engine.calls.isNotEmpty);
        await engine.calls.single.publish();
        expect(await retry.result, isNotNull);
        expect(inspections, 2);
      } finally {
        engine.finish();
        await shared.close();
        await engine.close();
      }
    },
  );
}

class _PageEngine extends ControlledEngine {
  final calls = <_Call>[];
  final scopes = <podoco.FormulaScope>[];
  @override
  DocumentAnalysisJob analyzePage(
    podoco.PageSource pages,
    int pageIndex,
    Future<void> Function(podoco.AnalysisUpdate) sink, {
    podoco.FormulaScope formulaScope = podoco.FormulaScope.none,
  }) {
    final call = _Call(pages.pages[pageIndex].key, sink);
    calls.add(call);
    scopes.add(formulaScope);
    return call.job;
  }

  void finish() {
    for (final call in calls) {
      call.job.finish();
    }
  }

  @override
  Future<void> close() async {
    closeCount++;
    finish();
  }
}

class _Call {
  _Call(this.page, this.sink);
  final podoco.PageKey page;
  final Future<void> Function(podoco.AnalysisUpdate) sink;
  final job = ControlledJob();
  Future<void> publish() =>
      sink(analysisFixture(page.document, pageIndex: page.pageIndex));
}
