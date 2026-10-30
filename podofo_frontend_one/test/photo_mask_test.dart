import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:podofo_one/src/dark_mode/photo_mask.dart';

void main() {
  testWidgets('mask requests coalesce, reuse and discard stale generations', (
    tester,
  ) async {
    final jobs = <Completer<PhotoMask>>[];
    final cache = PhotoMaskCache(
      builder: (bounds, rectangles) {
        final job = Completer<PhotoMask>();
        jobs.add(job);
        return job.future;
      },
    );
    const bounds = ui.Rect.fromLTWH(100, 200, 400, 500);
    const a = ui.Rect.fromLTWH(120, 240, 50, 50);
    const b = ui.Rect.fromLTWH(220, 340, 50, 50);
    Future<PhotoMask> small(ui.Rect r) async {
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder)
          .drawColor(const ui.Color(0xffffffff), ui.BlendMode.src);
      final picture = recorder.endRecording();
      try {
        return PhotoMask(await picture.toImage(2, 2), bounds, {r});
      } finally {
        picture.dispose();
      }
    }

    cache.request(bounds, [a]);
    await tester.pump(const Duration(milliseconds: 1));
    expect(jobs.length, 1);
    cache.request(bounds, [b]);
    cache.invalidate(); // session or page-layout revision while building
    cache.request(bounds, [a, b]);
    await tester.runAsync(() async {
      jobs[0].complete(await small(a));
    });
    await tester.pump(const Duration(milliseconds: 1));
    expect(cache.current, isNull);
    expect(jobs.length, 2, reason: 'Only the latest request survives');
    late PhotoMask accepted;
    await tester.runAsync(() async {
      accepted = await small(b);
      jobs[1].complete(accepted);
    });
    await tester.pump(const Duration(milliseconds: 1));
    expect(cache.current, same(accepted));
    for (var i = 0; i < 20; i++) {
      cache.request(bounds, [a, b]);
    }
    await tester.pump(const Duration(milliseconds: 1));
    expect(cache.builds, 2);
    cache.request(bounds, [a]);
    await tester.pump(const Duration(milliseconds: 1));
    cache.dispose();
    await tester.runAsync(() async {
      jobs[2].complete(await small(a));
    });
    await tester.pump(const Duration(milliseconds: 1));
    expect(cache.current, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'failed texture builds stop retrying and an empty request clears coverage',
    (tester) async {
      final cache = PhotoMaskCache(
        builder: (_, _) async => throw StateError('GPU unavailable'),
      );
      const bounds = ui.Rect.fromLTWH(0, 0, 100, 100);
      const region = ui.Rect.fromLTWH(10, 10, 50, 50);
      cache.request(bounds, [region]);
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump(const Duration(milliseconds: 1));
      expect(cache.failed, isTrue);
      for (var i = 0; i < 10; i++) {
        cache.request(bounds, [region]);
      }
      await tester.pump(const Duration(milliseconds: 1));
      expect(cache.builds, 1);
      cache.request(bounds, []);
      expect(cache.current, isNull);
      expect(cache.failed, isFalse);
      cache.dispose();
    },
  );
}
