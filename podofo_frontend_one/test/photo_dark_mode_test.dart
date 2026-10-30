import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:podofo_one/src/dark_mode/photo_analysis.dart';
import 'package:podofo_one/src/dark_mode/photo_cache.dart';
import 'package:podofo_one/src/dark_mode/photo_classifier.dart';
import 'package:podofo_one/src/dark_mode/photo_geometry.dart';
import 'package:podofo_one/src/providers/theme_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'photo passes; plot, screenshot, gradient and gray ambiguity stay inverted',
    () {
      for (final name in ['photo', 'plot', 'screenshot', 'gradient', 'gray']) {
        final pixels = File('test/fixtures/photo_dark_mode/$name.rgb')
            .readAsBytesSync();
        final result = classifyPhoto(pixels);
        expect(
          result.isLikelyPhoto,
          name == 'photo',
          reason: '$name: ${result.reason}',
        );
      }
      expect(classifyPhoto(Uint8List(0)).reason, 'invalid-sample');
      expect(classifyPhoto(Uint8List(64 * 64 * 3)).isLikelyPhoto, false);
      expect(
        classifyPhoto(Uint8List(64 * 64 * 3)..fillRange(0, 64 * 64 * 3, 255))
            .isLikelyPhoto,
        false,
      );
    },
  );

  test('existing preferences default to whole-view inversion; opt-in persists independently', () async {
    SharedPreferences.setMockInitialValues({
      'shaderPreference': true,
      'shaderStrength': .7,
    });
    var container = ProviderContainer();
    var prefs = await container.read(userPreferenceProvider.future);
    expect(prefs.preservePhotos, false);
    expect(prefs.shaderPreference, true);
    await container
        .read(userPreferenceProvider.notifier)
        .setPreservePhotos(true);
    expect(container.read(userPreferenceProvider).value!.shaderStrength, .7);
    container.dispose();
    container = ProviderContainer();
    prefs = await container.read(userPreferenceProvider.future);
    expect(prefs.preservePhotos, true);
    await container.read(userPreferenceProvider.notifier).setShaderStrength(.4);
    expect(container.read(preservePhotosProvider), true);
    await container
        .read(userPreferenceProvider.notifier)
        .setPreservePhotos(false);
    expect(container.read(shaderPreferenceProvider), true);
    container.dispose();
  });

  test(
    'visible row lookup handles unequal spread heights and single pages',
    () {
      const layout = [
        Rect.fromLTWH(0, 0, 100, 200),
        Rect.fromLTWH(110, 50, 100, 100),
        Rect.fromLTWH(0, 210, 100, 100),
        Rect.fromLTWH(110, 210, 100, 100),
      ];
      expect(
        visiblePhotoPages(
          layout,
          const Rect.fromLTWH(0, 170, 210, 30),
          twoPages: true,
        ),
        [1],
      );
      expect(
        visiblePhotoPages(
          layout,
          const Rect.fromLTWH(110, 0, 100, 400),
          twoPages: true,
        ),
        [2, 4],
      );
      expect(
        visiblePhotoPages(
          const [
            Rect.fromLTWH(0, 0, 100, 100),
            Rect.fromLTWH(0, 110, 100, 100),
          ],
          const Rect.fromLTWH(0, 100, 100, 20),
          twoPages: false,
        ),
        [2],
      );
      expect(visiblePhotoPages([], Rect.zero, twoPages: true), isEmpty);
    },
  );

  test(
    'analysis coalesces work, caches failures, and bounds retained pages',
    () async {
      final calls = <int>[];
      final cache = PhotoAnalysisCache(
        (page, previous, priority) async {
          calls.add(page);
          if (page == 2) throw StateError('unsupported');
          return const PhotoPageAnalysis();
        },
        capacity: 2,
        settleDelay: Duration.zero,
      );
      addTearDown(cache.dispose);
      cache.setVisiblePages([1, 2]);
      await _idle(cache);
      for (var i = 0; i < 100; i++) {
        cache.setVisiblePages([1, 2]);
        cache.peek(1);
        cache.peek(2);
      }
      expect(calls, [1, 2]);
      expect(cache.peek(2)!.fallback, 'analysis-unavailable');
      cache.setVisiblePages([3, 4, 5]);
      await _idle(cache);
      expect(cache.length, 2);
      expect(calls, [1, 2, 3, 4]);
    },
  );

  test('revision invalidation discards an in-flight result', () async {
    final first = Completer<PhotoPageAnalysis>();
    var calls = 0;
    final cache = PhotoAnalysisCache((_, previous, priority) {
      calls++;
      return calls == 1
          ? first.future
          : Future.value(const PhotoPageAnalysis(fallback: 'new-revision'));
    }, settleDelay: Duration.zero);
    addTearDown(cache.dispose);
    cache.setVisiblePages([1]);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    cache.invalidate();
    cache.setVisiblePages([1]);
    first.complete(const PhotoPageAnalysis(fallback: 'stale'));
    await _idle(cache);
    expect(cache.peek(1)!.fallback, 'new-revision');
    expect(calls, 2);
  });

  test(
    'dispose and disable stop queued work without publishing stale results',
    () async {
      final first = Completer<PhotoPageAnalysis>();
      var calls = 0;
      var notifications = 0;
      final cache = PhotoAnalysisCache((_, previous, priority) {
        calls++;
        return first.future;
      }, settleDelay: Duration.zero);
      cache.addListener(() => notifications++);
      cache.setVisiblePages([1, 2]);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      cache.setVisiblePages([]);
      cache.dispose();
      first.complete(const PhotoPageAnalysis());
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(calls, 1);
      expect(notifications, 0);
    },
  );
  test(
    'pending pages alternate fairly and completed pages are not retried',
    () async {
      final calls = <int>[];
      final cache = PhotoAnalysisCache(
        (page, previous, priority) async {
          calls.add(page);
          return PhotoPageAnalysis(
            pendingCount: (previous?.pendingCount ?? 4) - 1,
          );
        },
        settleDelay: Duration.zero,
        batchDelay: Duration.zero,
      );
      addTearDown(cache.dispose);
      cache.setVisiblePages([1, 2]);
      await _idle(cache);
      expect(calls, [1, 2, 1, 2, 1, 2, 1, 2]);
      expect(cache.peek(1)!.isComplete, isTrue);
      cache.setVisiblePages([2, 1]);
      await _idle(cache);
      expect(calls.length, 8);
    },
  );

  test(
    'leaving a pending page pauses work and returning resumes saved progress',
    () async {
      final first = Completer<PhotoPageAnalysis>();
      var calls = 0;
      final seen = <PhotoPageAnalysis?>[];
      final priorities = <List<String>>[];
      final cache = PhotoAnalysisCache(
        (page, previous, priority) {
          calls++;
          seen.add(previous);
          priorities.add(priority);
          return calls == 1
              ? first.future
              : Future.value(const PhotoPageAnalysis());
        },
        settleDelay: Duration.zero,
        batchDelay: Duration.zero,
      );
      addTearDown(cache.dispose);
      cache.setVisiblePages([1]);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      cache.setVisiblePages([]);
      const partial = PhotoPageAnalysis(pendingCount: 2);
      first.complete(partial);
      await _idle(cache);
      expect(calls, 1);
      expect(cache.peek(1), same(partial));
      cache.setVisiblePages(
        [1],
        priorities: {
          1: ['3/7'],
        },
      );
      await _idle(cache);
      expect(calls, 2);
      expect(seen.last, same(partial));
      expect(priorities.last, ['3/7']);
    },
  );

  test(
    'a failed or stalled continuation preserves completed decisions and stops',
    () async {
      const region = PhotoRegion(0, 0, 100, 100);
      const partial = PhotoPageAnalysis(
        regions: [region],
        pendingCount: 1,
        candidates: [
          PhotoCandidate(0, 'likely-photo', region: region),
          PhotoCandidate(1, 'pending', region: region),
        ],
      );
      for (final throws in [false, true]) {
        var calls = 0;
        final cache = PhotoAnalysisCache(
          (page, previous, priority) async {
            calls++;
            if (calls == 1 || !throws) return partial;
            throw StateError('decoder failed');
          },
          settleDelay: Duration.zero,
          batchDelay: Duration.zero,
        );
        cache.setVisiblePages([1]);
        await _idle(cache);
        final result = cache.peek(1)!;
        expect(calls, 2);
        expect(result.isComplete, isTrue);
        expect(result.regions, [region]);
        expect(result.candidates.first.reason, 'likely-photo');
        expect(
          result.fallback,
          throws ? 'analysis-unavailable' : 'analysis-stalled',
        );
        cache.dispose();
      }
    },
  );
}

Future<void> _idle(PhotoAnalysisCache cache) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  do {
    await Future<void>.delayed(const Duration(milliseconds: 2));
    if (DateTime.now().isAfter(deadline)) fail('Cache did not settle');
  } while (!cache.isIdle);
}
