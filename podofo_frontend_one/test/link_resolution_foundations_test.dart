import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:podoco/podoco.dart' as podoco;
import 'package:podofo_one/src/previews/link_target.dart';
import 'package:podofo_one/src/previews/link_target_resolver.dart';
import 'package:podofo_one/src/previews/pdf_link_context.dart';
import 'package:podofo_one/src/previews/preview_geometry.dart';
import 'package:podofo_one/src/narration/source_map.dart';
import 'package:podofo_one/src/analysis/analysis_controller.dart';
import 'package:podofo_one/src/analysis/preview_layout_repository.dart';
import 'package:podofo_one/src/analysis/analysis_store.dart';
import 'package:podofo_one/src/analysis/pdf_analysis_source.dart';
import 'package:podofo_one/src/services/pdf_session.dart';
import 'package:podofo_one/src/data/pdf_document_lease.dart';
import 'package:podofo_one/src/workers/link_preview_worker.dart';

import 'fixtures/hover_pdf_fixture.dart';
import 'fixtures/analysis_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  setUpAll(() async {
    temp = await Directory.systemTemp.createTemp('preview-m1-');
    await pdfrxInitialize(tmpPath: temp.path);
  });
  tearDownAll(() async {
    await PdfrxEntryFunctions.instance.stopBackgroundWorker();
    await temp.delete(recursive: true);
  });
  Future<PdfSession> open([String xyz = '400 540 null']) async {
    final file = File(
      '${temp.path}/${DateTime.now().microsecondsSinceEpoch}.pdf',
    );
    await file.writeAsBytes(hoverPdfFixture(firstLocation: xyz));
    return PdfSession.open(file.path);
  }

  LinkPreviewRequest request(PdfSession s, PdfLink l, {int index = 0}) =>
      LinkPreviewRequest(
        session: s,
        sourcePage: 1,
        annotationIndex: index,
        sourceRects: l.rects,
        destination: l.dest!,
        pixelRatio: 1,
      );

  test('native XYZ distinguishes null, zero and missing zoom', () async {
    for (final pair in <(String, List<double?>)>[
      ('null 0 null', [null, 0, null]),
      // PDFium interprets zero zoom as keeping the current zoom.
      ('0 null 0', [0, null, null]),
      ('0 0 2', [0, 0, 2]),
      ('null null null', [null, null, null]),
    ]) {
      final s = await open(pair.$1);
      try {
        final links = await s.lease.document.pages.first.loadLinks();
        expect(links.first.dest!.params, pair.$2);
      } finally {
        await s.close();
      }
    }
  });

  test('native rotated/cropped geometry and text use the same displayed coordinates', () async {
    final s = await open();
    final context = PdfLinkContext();
    try {
      final pdf = s.lease.document;
      final links = await pdf.pages.first.loadLinks();
      for (var i = 0; i < 4; i++) {
        final r = request(s, links[i]);
        final prepared = (await context.prepare(r, () => true, null))!;
        final page = pdf.pages[i + 1];
        final bounds = (await previewPageBounds(pdf, i + 2))!;
        final point = normalizePreviewDestination(page, r.destination, bounds)!;
        final area = normalizePreviewDestination(
          page,
          PdfDest(i + 2, PdfDestCommand.fitR, [400, 500, 460, 540]),
          bounds,
        )!;
        final resolved = const LinkTargetResolver().resolve(area);
        expect(resolved.tier, LinkTargetTier.explicitArea);
        expect(
          resolved.parts.single.bounds
              .inflate(.01)
              .contains(Offset(point.x!, point.y!)),
          true,
        );
        expect(prepared.resolution.tier, LinkTargetTier.unresolved);
        expect(
          prepared.source!.spans.map((v) => v.text).join(),
          contains(i == 0 ? 'Citation' : 'Figure'),
        );
        final t = prepared.targetText!;
        final start = t.snapshot.text.indexOf('Linked');
        expect(start, greaterThanOrEqualTo(0));
        final expected = t.snapshot.boxes[start].toRect(page: page);
        expect(t.boxes[start], expected);
        expect((Offset.zero & page.size).contains(expected.center), true);
        final raster = (await page.render())!;
        try {
          var dark = 0;
          final sx = raster.width / page.width,
              sy = raster.height / page.height;
          for (
            var y = (expected.top * sy).floor().clamp(0, raster.height - 1);
            y < (expected.bottom * sy).ceil().clamp(0, raster.height);
            y++
          ) {
            for (
              var x = (expected.left * sx).floor().clamp(0, raster.width - 1);
              x < (expected.right * sx).ceil().clamp(0, raster.width);
              x++
            ) {
              final at = (y * raster.width + x) * 4;
              if (raster.pixels[at] < 80 &&
                  raster.pixels[at + 1] < 80 &&
                  raster.pixels[at + 2] < 80) {
                dark++;
              }
            }
          }
          expect(
            dark,
            greaterThan(0),
            reason: 'actual Linked glyph pixels at rotation $i',
          );
        } finally {
          raster.dispose();
        }

        final partial = normalizePreviewDestination(
          page,
          PdfDest(i + 2, PdfDestCommand.xyz, [null, 540, null]),
          bounds,
        )!;
        expect(i.isOdd ? partial.y : partial.x, isNull);
        expect(i.isOdd ? partial.x : partial.y, isNotNull);
        expect(
          normalizePreviewDestination(
            page,
            PdfDest(i + 2, PdfDestCommand.fitR, [1, 2, 0, 3]),
            bounds,
          ),
          isNull,
        );
        expect(
          normalizePreviewDestination(
            page,
            PdfDest(i + 2, PdfDestCommand.xyz, [double.nan, 0]),
            bounds,
          ),
          isNull,
        );
      }
      expect(context.bytes, lessThanOrEqualTo(context.maxBytes));
      expect(s.navigationHistory.previous, isNull);
      expect(s.dirty, false);
    } finally {
      context.clear();
      await s.close();
    }
  });

  test(
    'worker publishes explicit FitR evidence and invalidates it after edits',
    () async {
      final s = await open();
      final worker = LinkPreviewWorker();
      try {
        final link = (await s.lease.document.pages.first.loadLinks())[5];
        final r = request(s, link, index: 5);
        final image = await worker.load(
          s,
          link.dest!,
          pixelRatio: 1,
          request: r,
        );
        expect(image, isNotNull);
        image!.dispose();
        for (var i = 0; i < 100 && worker.prepared == null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(worker.prepared!.resolution.tier, LinkTargetTier.explicitArea);
        expect(worker.prepared!.resolution.parts.single.page, 3);
        s.revision++;
        expect(worker.prepared, isNull);
        worker.reset();
        expect(worker.context.bytes, 0);
      } finally {
        worker.dispose();
        await s.close();
      }
    },
  );

  test('source identity distinguishes links sharing a destination and keys evidence versions', () async {
    final s = await open();
    try {
      final l = (await s.lease.document.pages.first.loadLinks()).first;
      final a = request(s, l), b = request(s, l, index: 1);
      final resolver = const LinkTargetResolver();
      final x = resolver.resolve(null, evidenceIdentity: 'first');
      expect(x.cacheKey(a), isNot(x.cacheKey(b)));
      expect(
        x.cacheKey(a),
        isNot(resolver.resolve(null, evidenceIdentity: 'second').cacheKey(a)),
      );
      s.revision++;
      expect(a.isCurrent, false);
    } finally {
      await s.close();
    }
  });

  test(
    'source spans preserve offsets, disjoint lines, UTF-16 and bounded context',
    () {
      final text = '${'a' * 300}AB😀CD${'z' * 300}';
      final snap = PdfTextSnapshot(
        page: 1,
        text: text,
        boxes: List.filled(text.length, const PdfRect(0, 1, 1, 0)),
      );
      final boxes = List.filled(text.length, const Rect.fromLTWH(10, 10, 1, 1));
      for (var i = 300; i < 306; i++) {
        boxes[i] = const Rect.fromLTWH(0, 0, 1, 1);
      }
      final source = sourceLinkText(PreviewTextPage(snap, boxes), [
        const Rect.fromLTWH(0, 0, 2, 2),
      ]);
      expect(source.spans.single.start, 300);
      expect(source.spans.single.end, 306);
      expect(source.spans.single.text, 'AB😀CD');
      expect(source.before.length, 256);
      expect(source.after.length, 256);
      final large = PdfTextSnapshot(
        page: 1,
        text: '${'x' * 2047}😀${'y' * 50}',
        boxes: List.filled(2099, const PdfRect(0, 1, 1, 0)),
      );
      final bounded = sourceLinkText(
        PreviewTextPage(
          large,
          List.filled(2099, const Rect.fromLTWH(0, 0, 1, 1)),
        ),
        [const Rect.fromLTWH(0, 0, 2, 2)],
      );
      expect(bounded.truncated, true);
      expect(bounded.spans.single.text.length, 2047);
      boxes[302] = const Rect.fromLTWH(10, 10, 1, 1);
      boxes[303] = boxes[302];
      expect(
        sourceLinkText(PreviewTextPage(snap, boxes), [
          const Rect.fromLTWH(0, 0, 2, 2),
        ]).spans.length,
        2,
      );
    },
  );

  test(
    'text budget, permissions, eviction and stale extraction are bounded',
    () async {
      final s = _Session();
      final context = PdfLinkContext(maxPages: 1, maxBytes: 1000);
      LinkPreviewRequest r() => LinkPreviewRequest(
        session: s,
        sourcePage: 1,
        annotationIndex: 0,
        sourceRects: [],
        destination: const PdfDest(1, PdfDestCommand.fit, null),
        pixelRatio: 1,
      );
      try {
        expect(await context.text(r(), 1, () => true), isNotNull);
        expect(context.length, 1);
        final first = s.native.pages[0].loads;
        await context.text(r(), 1, () => true);
        expect(s.native.pages[0].loads, first);
        await context.text(r(), 2, () => true);
        expect(context.length, 1);
        await context.text(r(), 1, () => true);
        expect(s.native.pages[0].loads, first + 1);
        context.clear();
        s.native.permissions = const PdfPermissions(0, 3);
        expect(await context.text(r(), 1, () => true), isNull);
        s.native.permissions = null;
        s.native.pages[0].value = 'x' * 200001;
        expect(await context.text(r(), 1, () => true), isNull);
        s.native.pages[0].value = 'x' * 100;
        expect(
          await context.text(r(), 1, () => true),
          isNull,
        ); // accounted geometry exceeds 1000
        s.native.pages[0].value = 'ok';
        s.native.pages[0].gate = Completer<void>();
        final pending = context.text(r(), 1, () => true);
        await Future<void>.delayed(Duration.zero);
        s.revision++;
        s.native.pages[0].gate!.complete();
        expect(await pending, isNull);
        expect(context.bytes, 0);
      } finally {
        context.clear();
        s.lease.close();
      }
    },
  );

  test('offscreen progressive read preserves visible state and stored bytes; mismatches miss', () async {
    final s = await open();
    final store = AnalysisStore(Directory('${temp.path}/cache'));
    final controller = AnalysisController(store: store);
    try {
      controller.select(s, 0);
      expect(controller.previewIdentity, isNull); // no model load
      final doc = analysisDocumentRef(s);
      final identity = PreviewAnalysisIdentity(
        doc,
        [fixtureManifest],
        fixtureProfile,
        podoco.ComputePolicy.cpuOnly,
      );
      await store.write(
        identity.key,
        analysisFixture(doc, pageIndex: 1),
        () => true,
      );
      controller.visibleSnapshot = AnalysisPageSnapshot.fromUpdate(
        analysisFixture(doc),
      );
      final visible = controller.visibleSnapshot;
      var notifications = 0;
      controller.addListener(() => notifications++);
      final file = File('${store.directory.path}/${identity.key}-1.json');
      final before = await file.readAsBytes();
      final r = request(
        s,
        (await s.lease.document.pages.first.loadLinks()).first,
      );
      final repo = PreviewLayoutRepository(store, identity);
      final evidence = (await repo.read(r, isCurrent: () => true))!;
      expect(evidence.layoutReady, true);
      expect(evidence.page.provenance.pipeline.profile, fixtureProfile);
      expect(identical(controller.visibleSnapshot, visible), true);
      expect(notifications, 0);
      expect(await file.readAsBytes(), before);
      expect(s.navigationHistory.previous, isNull);
      final wrong = PreviewAnalysisIdentity(
        doc,
        [fixtureManifest],
        'other',
        podoco.ComputePolicy.cpuOnly,
      );
      expect(
        await PreviewLayoutRepository(
          store,
          wrong,
        ).read(r, isCurrent: () => true),
        isNull,
      );
      await file.writeAsString('{corrupt');
      expect(await repo.read(r, isCurrent: () => true), isNull);
      s.revision++;
      expect(await repo.read(r, isCurrent: () => true), isNull);
    } finally {
      await controller.close();
      controller.dispose();
      await s.close();
    }
  });

  for (final action in ['cancel', 'revision', 'close']) {
    test(
      'context renders before cache IO; $action suppresses late preparation without holding PDF lock',
      () async {
        final s = await open();
        final store = _DelayedStore(Directory('${temp.path}/delayed'));
        final identity = PreviewAnalysisIdentity(
          analysisDocumentRef(s),
          [fixtureManifest],
          fixtureProfile,
          podoco.ComputePolicy.cpuOnly,
        );
        final worker = LinkPreviewWorker();
        try {
          final l = (await s.lease.document.pages.first.loadLinks()).first;
          final r = request(s, l);
          final image = await worker.load(
            s,
            l.dest!,
            pixelRatio: 1,
            request: r,
            repository: PreviewLayoutRepository(store, identity),
          );
          expect(image, isNotNull);
          image!.dispose();
          await store.started.future.timeout(const Duration(seconds: 5));
          await s.readLocked((_) async {}).timeout(const Duration(seconds: 1));
          if (action == 'close') {
            await s.close().timeout(const Duration(seconds: 1));
          } else if (action == 'revision') {
            s.revision++;
          } else {
            worker.cancel();
          }
          store.release.complete();
          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect(worker.prepared, isNull);
        } finally {
          if (!store.release.isCompleted) store.release.complete();
          worker.dispose();
          if (!s.lease.isClosed) await s.close();
        }
      },
    );
  }
}

class _DelayedStore extends AnalysisStore {
  _DelayedStore(super.directory);
  final started = Completer<void>(), release = Completer<void>();
  @override
  Future<AnalysisPageSnapshot?> read(
    String key,
    int pageIndex,
    podoco.DocumentRef document,
  ) async {
    started.complete();
    await release.future;
    return null;
  }
}

class _Page implements PdfPage {
  _Page(this.pageNumber);
  String value = 'ok';
  int loads = 0;
  Completer<void>? gate;
  @override
  final int pageNumber;
  @override
  double get width => 100;
  @override
  double get height => 100;
  @override
  PdfPageRotation get rotation => PdfPageRotation.none;
  @override
  Future<PdfPageRawText?> loadText() async {
    loads++;
    await gate?.future;
    return PdfPageRawText(
      value,
      List.filled(value.length, const PdfRect(0, 1, 1, 0)),
    );
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Document implements PdfDocument {
  @override
  final List<_Page> pages = [_Page(1), _Page(2)];
  @override
  PdfPermissions? permissions;
  @override
  String get sourceName => 'm1-fake';
  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Session implements PdfSession {
  final native = _Document();
  @override
  late final lease = PdfDocumentLease(native);
  @override
  int revision = 0;
  @override
  Future<T> readLocked<T>(Future<T> Function(PdfDocument) read) =>
      lease.use(read);
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}
