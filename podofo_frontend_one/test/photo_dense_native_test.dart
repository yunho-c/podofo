import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:podofo_one/src/dark_mode/photo_analysis.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PdfDocument pdf;
  setUpAll(() async {
    await pdfrxInitialize();
    pdf = await PdfDocument.openFile('test/fixtures/photo_dark_mode/dense.pdf');
  });
  tearDownAll(() async {
    await pdf.dispose();
    await PdfrxEntryFunctions.instance.stopBackgroundWorker();
  });

  test('92 nested photos resume across image, pixel and time slices', () async {
    var result = await analyzePhotoBatch(pdf, 2);
    expect(result.totalImages, 92);
    expect(result.pendingCount, 92);
    expect(result.batchDecodedImages, 0);
    expect(result.fallback, isNull);
    result = await analyzePhotoBatch(
      pdf,
      2,
      previous: result,
      priority: ['1/91'],
      maxImages: 3,
      timeBudget: const Duration(seconds: 1),
    );
    expect(result.batchDecodedImages, 3);
    expect(result.candidates.last.reason, 'likely-photo');
    var decoded = result.batchDecodedImages;
    var pixels = result.batchDecodedPixels;
    result = await analyzePhotoBatch(
      pdf,
      2,
      previous: result,
      maxPixels: 300000,
      timeBudget: const Duration(seconds: 1),
    );
    expect(result.batchDecodedImages, 1);
    expect(result.batchDecodedPixels, lessThanOrEqualTo(300000));
    decoded += result.batchDecodedImages;
    pixels += result.batchDecodedPixels;
    result = await analyzePhotoBatch(
      pdf,
      2,
      previous: result,
      timeBudget: Duration.zero,
    );
    expect(
      result.batchDecodedImages,
      1,
      reason: 'Even an expired slice makes progress',
    );
    decoded += result.batchDecodedImages;
    pixels += result.batchDecodedPixels;
    while (!result.isComplete) {
      final prior = {
        for (final c in result.candidates.where((c) => c.reason != 'pending'))
          c.objectId: c.reason,
      };
      final next = await analyzePhotoBatch(pdf, 2, previous: result);
      expect(next.pendingCount, lessThan(result.pendingCount));
      expect(next.batchDecodedImages, lessThanOrEqualTo(8));
      expect(next.batchDecodedPixels, lessThanOrEqualTo(8000000));
      for (final c in next.candidates) {
        if (prior.containsKey(c.objectId)) expect(c.reason, prior[c.objectId]);
      }
      decoded += next.batchDecodedImages;
      pixels += next.batchDecodedPixels;
      result = next;
    }
    expect(decoded, 92, reason: 'Completed images must not be decoded again');
    expect(pixels, greaterThan(8000000));
    expect(result.regions, hasLength(92));
    expect(result.inspectedImages, 92);
    expect(result.candidates.every((c) => c.reason == 'likely-photo'), isTrue);
  });

  test('25-panel and rotated 92-panel pages fully complete', () async {
    expect((await analyzePhotos(pdf, 1)).regions, hasLength(25));
    expect((await analyzePhotos(pdf, 3)).regions, hasLength(92));
  });
}
