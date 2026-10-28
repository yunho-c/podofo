import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:podofo_one/src/data/pdf_document_lease.dart';
import 'package:podofo_one/src/services/pdf_session.dart';
import 'package:podofo_one/src/workers/link_preview_worker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const bounds = PdfRect(30, 800, 590, 40);
  const destination = PdfDest(2, PdfDestCommand.xyz, [400, 540, 12]);

  test(
    'destination crop subtracts the crop origin and follows all rotations',
    () {
      const targets = [
        ui.Offset(370, 260),
        ui.Offset(500, 370),
        ui.Offset(190, 500),
        ui.Offset(260, 190),
      ];
      for (final rotation in PdfPageRotation.values) {
        final page = _Page(rotation: rotation);
        final region = LinkPreviewRegion.forDestination(
          page,
          destination,
          bounds,
          4,
        )!;
        expect(region.rect.contains(targets[rotation.index]), true);
        expect(region.width, lessThanOrEqualTo(720));
        expect(region.height, lessThanOrEqualTo(480));
        expect(region.pixelRatio, 2);
        expect(region.rect.left, greaterThanOrEqualTo(0));
        expect(region.rect.top, greaterThanOrEqualTo(0));
        expect(region.rect.right, lessThanOrEqualTo(page.width));
        expect(region.rect.bottom, lessThanOrEqualTo(page.height));
      }
      final region = LinkPreviewRegion.forDestination(
        _Page(),
        destination,
        bounds,
        2,
      )!;
      expect(
        region.rect,
        const ui.Rect.fromLTWH(80, 100, 480, 320),
      ); // right edge clamps to page width
      // Destination zoom and viewer zoom do not enlarge raster allocations.
      final other = LinkPreviewRegion.forDestination(
        _Page(),
        const PdfDest(2, PdfDestCommand.xyz, [400, 540, .01]),
        bounds,
        2,
      )!;
      expect(other.rect, region.rect);
      expect(other.width, region.width);
    },
  );

  test(
    'page-only and nullable destinations fit the page; FitR retains its area',
    () {
      for (final dest in [
        const PdfDest(2, PdfDestCommand.fit, null),
        const PdfDest(2, PdfDestCommand.fitB, null),
        const PdfDest(2, PdfDestCommand.xyz, [null, null, null]),
        const PdfDest(2, PdfDestCommand.fitH, [null]),
        const PdfDest(2, PdfDestCommand.fitV, null),
      ]) {
        final plan = LinkPreviewRegion.forDestination(
          _Page(),
          dest,
          bounds,
          1,
        )!;
        expect(plan.rect, const ui.Rect.fromLTWH(0, 0, 560, 760));
        expect(plan.height, 240);
        expect(plan.width, lessThan(360));
      }
      final rect = LinkPreviewRegion.forDestination(
        _Page(),
        const PdfDest(2, PdfDestCommand.fitR, [400, 500, 460, 540]),
        bounds,
        2,
      )!;
      expect(rect.rect, const ui.Rect.fromLTRB(358, 248, 442, 312));
      for (final command in [
        PdfDestCommand.fitH,
        PdfDestCommand.fitBH,
        PdfDestCommand.fitV,
        PdfDestCommand.fitBV,
      ]) {
        expect(
          LinkPreviewRegion.forDestination(
            _Page(),
            PdfDest(2, command, [500]),
            bounds,
            1,
          ),
          isNotNull,
        );
      }
    },
  );

  test('malformed destinations and unsafe dimensions fall back to a label', () {
    for (final dest in [
      const PdfDest(2, PdfDestCommand.unknown, null),
      const PdfDest(2, PdfDestCommand.xyz, [double.nan, 20]),
      const PdfDest(2, PdfDestCommand.xyz, [0, double.infinity]),
      const PdfDest(2, PdfDestCommand.fitR, [10, 20, 5, 30]),
      const PdfDest(2, PdfDestCommand.fitR, [10, null, 50, 30]),
      const PdfDest(2, PdfDestCommand.fitR, [10, 20]),
    ]) {
      expect(
        LinkPreviewRegion.forDestination(_Page(), dest, bounds, 2),
        isNull,
      );
    }
    expect(
      LinkPreviewRegion.forDestination(
        _Page(width: double.infinity),
        destination,
        bounds,
        2,
      ),
      isNull,
    );
    expect(
      LinkPreviewRegion.forDestination(
        _Page(width: 1e9),
        destination,
        bounds,
        2,
      ),
      isNull,
    );
    expect(boundedPreviewPixelRatio(double.nan), 1);
  });

  test('decoded LRU bounds bytes and entries, disposes and preserves caller clones', () async {
    final cache = LinkPreviewCache(maxBytes: 800, maxEntries: 2);
    final first = await _image();
    cache.put('a', first);
    final second = await _image();
    cache.put('b', second);
    final caller = cache.get('a')!;
    cache.put('c', await _image());
    expect(second.debugDisposed, true);
    expect(first.debugDisposed, false);
    expect(cache.get('b'), isNull);
    expect(cache.bytes, 800);
    expect(cache.length, 2);
    final oversize = await _image(20);
    cache.put('large', oversize);
    expect(oversize.debugDisposed, true);
    cache.clear();
    expect(first.debugDisposed, true);
    expect(caller.debugDisposed, false);
    expect((await caller.toByteData())!.lengthInBytes, 400);
    caller.dispose();
    expect(cache.bytes, 0);
  });

  test('rapid requests keep one active and the newest pending; stale images dispose', () async {
    final session = _Session();
    final firstStarted = Completer<void>();
    final unblock = Completer<ui.Image?>();
    final cancelledToken = _Token();
    final pages = <int>[];
    final worker = LinkPreviewWorker(
      render: (pdf, dest, ratio, cancel) async {
        pages.add(dest.pageNumber);
        if (pages.length == 1) {
          cancel.attach(cancelledToken);
          firstStarted.complete();
          return unblock.future;
        }
        return _image();
      },
    );
    final first = worker.load(session, destination, pixelRatio: 1);
    await firstStarted.future;
    final skipped = worker.load(
      session,
      const PdfDest(3, PdfDestCommand.fit, null),
      pixelRatio: 1,
    );
    final latest = worker.load(
      session,
      const PdfDest(4, PdfDestCommand.fit, null),
      pixelRatio: 1,
    );
    expect(await first, isNull);
    expect(await skipped, isNull);
    expect(cancelledToken.isCanceled, true);
    final stale = await _image();
    unblock.complete(stale);
    final image = await latest;
    expect(pages, [2, 4]);
    expect(stale.debugDisposed, true);
    expect(worker.cache.length, 1);
    image!.dispose();
    worker.dispose();
    session.lease.close();
  });

  test('cache keys use destination values, density, revision and session ownership', () async {
    var calls = 0;
    final worker = LinkPreviewWorker(
      render: (pdf, dest, ratio, cancel) async {
        calls++;
        return _image();
      },
    );
    final first = _Session();
    final second = _Session();
    for (var i = 0; i < 2; i++) {
      (await worker.load(
        first,
        PdfDest(2, PdfDestCommand.xyz, [400, 540, 12]),
        pixelRatio: 1,
      ))!.dispose();
    }
    expect(calls, 1);
    (await worker.load(first, destination, pixelRatio: 2))!.dispose();
    expect(calls, 2);
    first.revision++;
    (await worker.load(first, destination, pixelRatio: 2))!.dispose();
    expect(calls, 3);
    expect(worker.cache.length, 1);
    (await worker.load(second, destination, pixelRatio: 2))!.dispose();
    expect(calls, 4);
    expect(worker.cache.length, 1);
    worker.reset();
    expect(worker.cache.bytes, 0);
    worker.dispose();
    first.lease.close();
    second.lease.close();
  });

  test('closing retains the document until render completion and drops late images', () async {
    final session = _Session();
    final started = Completer<void>();
    final unblock = Completer<ui.Image?>();
    final worker = LinkPreviewWorker(
      render: (pdf, dest, ratio, cancel) {
        started.complete();
        return unblock.future;
      },
    );
    final pending = worker.load(session, destination, pixelRatio: 1);
    await started.future;
    session.lease.close();
    expect(session.native.disposals, 0);
    final image = await _image();
    unblock.complete(image);
    expect(await pending, isNull);
    expect(session.native.disposals, 1);
    expect(image.debugDisposed, true);
    expect(worker.cache.length, 0);
    worker.dispose();
  });

  test('reset, revision changes, failures and disposal never deliver late previews', () async {
    for (final action in ['reset', 'revision', 'dispose', 'throw']) {
      final session = _Session();
      final started = Completer<void>();
      final unblock = Completer<ui.Image?>();
      final worker = LinkPreviewWorker(
        render: (pdf, dest, ratio, cancel) {
          started.complete();
          return unblock.future;
        },
      );
      final pending = worker.load(session, destination, pixelRatio: 1);
      await started.future;
      switch (action) {
        case 'reset':
          worker.reset();
        case 'revision':
          session.revision++;
        case 'dispose':
          worker.dispose();
      }
      final image = action == 'throw' ? null : await _image();
      if (action == 'throw') {
        unblock.completeError(StateError('render failed'));
      } else {
        unblock.complete(image);
      }
      expect(await pending, isNull);
      // reset/dispose resolve the consumer early; allow native cleanup to finish.
      await Future<void>.delayed(Duration.zero);
      expect(image?.debugDisposed ?? true, true);
      expect(worker.cache.bytes, 0);
      worker.dispose();
      session.lease.close();
    }
  });
}

Future<ui.Image> _image([int size = 10]) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(const ui.Color(0xffff0000), ui.BlendMode.src);
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(size, size);
  } finally {
    picture.dispose();
  }
}

class _Page implements PdfPage {
  _Page({this.rotation = PdfPageRotation.none, double? width})
    : width = width ?? (rotation.index.isOdd ? 760 : 560),
      height = rotation.index.isOdd ? 560 : 760;
  @override
  final PdfPageRotation rotation;
  @override
  final double width, height;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Token implements PdfPageRenderCancellationToken {
  @override
  bool isCanceled = false;
  @override
  void cancel() => isCanceled = true;
}

class _Document implements PdfDocument {
  int disposals = 0;
  @override
  String get sourceName => 'preview-test.pdf';
  @override
  Future<void> dispose() async {
    disposals++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
