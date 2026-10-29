import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:podofo_one/src/dark_mode/photo_analysis.dart';
import 'package:podofo_one/src/dark_mode/photo_cache.dart';
import 'package:podofo_one/src/dark_mode/photo_geometry.dart';

/// Diagnostic timings, not a GPU/frame-time benchmark. Run without parallel tests.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('measure native analysis and cached viewport projection', () async {
    Pdfrx.pdfiumModulePath = Platform.environment['PDFIUM_PATH'];
    await pdfrxInitialize();
    final pdf = await PdfDocument.openFile(
      'test/fixtures/photo_dark_mode/mixed.pdf',
    );
    final times = <int>[];
    final renders = <int>[];
    final cache = PhotoAnalysisCache(
      (p) => analyzePhotos(pdf, p),
      settleDelay: Duration.zero,
    );
    try {
      for (var i = 0; i < 24; i++) {
        final watch = Stopwatch()..start();
        await analyzePhotos(pdf, i % pdf.pages.length + 1);
        times.add(watch.elapsedMicroseconds);
      }
      for (var i = 0; i < 12; i++) {
        final watch = Stopwatch()..start();
        final image = await pdf.pages[i].render(
          fullWidth: 600,
          fullHeight: 800,
        );
        image?.dispose();
        renders.add(watch.elapsedMicroseconds);
      }
      cache.setVisiblePages([1, 2]);
      while (!cache.isIdle) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      final page = pdf.pages.first;
      final watch = Stopwatch()..start();
      for (var i = 0; i < 10000; i++) {
        final result = cache.peek(1)!;
        for (final region in result.regions) {
          photoViewportRect(
            region,
            page,
            Rect.fromLTWH(10, 10, page.width, page.height),
            Rect.fromLTWH(0, i % 100, 600, 800),
          );
        }
      }
      final cachedMicros = watch.elapsedMicroseconds;
      expect(cache.analyses, 2);
      Map<String, Object> stats(List<int> values) {
        final sorted = values.toList()..sort();
        return {
          'count': values.length,
          'first_us': values.first,
          'min_us': sorted.first,
          'median_us': sorted[sorted.length ~/ 2],
          'max_us': sorted.last,
        };
      }

      final report = {
        'platform': Platform.operatingSystem,
        'dart': Platform.version,
        'pdfium_path': Pdfrx.pdfiumModulePath,
        'native_analysis_including_isolate_and_worker_lock': stats(times),
        'pdfium_page_render_600x800': stats(renders),
        'cached_10000_projections_total_us': cachedMicros,
        'cache_analyses_after_10000_projections': cache.analyses,
        'cache_pages': cache.length,
        'gpu_frame_overhead': 'not measured by this benchmark',
      };
      final output = File('build/photo-dark-mode/benchmark.json');
      output.parent.createSync(recursive: true);
      output.writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(report)}\n',
      );
      // ignore: avoid_print
      print(output.readAsStringSync());
    } finally {
      cache.dispose();
      await pdf.dispose();
      await PdfrxEntryFunctions.instance.stopBackgroundWorker();
    }
  });
}
