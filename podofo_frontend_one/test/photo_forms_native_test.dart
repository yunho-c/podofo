import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:pdfium_dart/pdfium_dart.dart';
import 'package:podofo_one/src/dark_mode/photo_analysis.dart';
import 'package:podofo_one/src/dark_mode/photo_overrides.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PdfDocument document;
  setUpAll(() async {
    await pdfrxInitialize();
    document = await PdfDocument.openFile(
      'test/fixtures/photo_dark_mode/forms.pdf',
    );
  });
  tearDownAll(() async {
    await document.dispose();
    await PdfrxEntryFunctions.instance.stopBackgroundWorker();
  });

  test('nested transforms, clips, paint order, masks and bounded traversal', () async {
    final manifest = jsonDecode(
      File('test/fixtures/photo_dark_mode/forms_manifest.json')
          .readAsStringSync(),
    );
    for (final spec in manifest['pages']) {
      final result = await analyzePhotos(document, spec['page']);
      final detail =
          '${spec['name']}: ${result.fallback}, ${result.candidates.map((c) => '${c.objectId}: ${c.reason}')}';
      expect(result.regions.length, spec['expectedPhotos'], reason: detail);
      if (spec['reason'] != null) {
        expect(
          [result.fallback, ...result.candidates.map((c) => c.reason)],
          contains(spec['reason']),
          reason: detail,
        );
      }
      if (spec['paths'] != null) {
        expect(
          result.candidates.map((c) => c.objectId),
          spec['paths'],
          reason: detail,
        );
      }
      if (spec['regions'] != null) {
        for (var i = 0; i < result.regions.length; i++) {
          final r = result.regions[i];
          final values = [r.left, r.bottom, r.right, r.top];
          for (var j = 0; j < 4; j++) {
            expect(
              values[j],
              closeTo(spec['regions'][i][j], .002),
              reason: detail,
            );
          }
        }
      }
    }
  });

  test(
    'intrinsic masks evade HasTransparency and retain only opaque coverage',
    () async {
      for (final number in [11, 12, 13]) {
        await document.useNativeDocumentHandle((handle) {
          final api = getPdfium(modulePath: Pdfrx.pdfiumModulePath);
          final page = api.FPDF_LoadPage(
            Pointer<fpdf_document_t__>.fromAddress(handle),
            number - 1,
          );
          try {
            final form = api.FPDFPage_GetObject(page, 0);
            final image = api.FPDFFormObj_GetObject(form, 0);
            expect(api.FPDFPageObj_HasTransparency(image), 0);
          } finally {
            api.FPDF_ClosePage(page);
          }
        });
        final result = await analyzePhotos(document, number);
        final candidate = result.candidates.single;
        expect(candidate.reason, 'likely-photo');
        expect(candidate.coverage, isNotNull);
        expect(candidate.coverage!.isFull, isFalse);
        expect(candidate.coverage!.isEmpty, isFalse);
        expect(candidate.coverage!.bits.length, lessThanOrEqualTo(8192));
        if (number != 13) {
          expect(candidate.coverage!.covers(.1, .1, .4, .9), isFalse);
          expect(candidate.coverage!.covers(.6, .1, .9, .9), isTrue);
        }
      }
    },
  );

  test(
    'coverage follows crop, local transforms and nested reflected Forms',
    () async {
      final hole = (await analyzePhotos(document, 27)).candidates.single;
      expect(hole.coverage!.covers(.05, .05, .25, .25), isTrue);
      expect(hole.coverage!.covers(.4, .4, .6, .6), isFalse);
      expect(
        hole.coverage!.covers(.32, .4, .35, .6),
        isFalse,
        reason: 'Fractional alpha must remain unpreserved',
      );
      for (final number in [30, 33]) {
        final c = (await analyzePhotos(document, number)).candidates.single;
        expect(c.coverage!.covers(.1, .1, .9, .4), isTrue);
        expect(c.coverage!.covers(.1, .6, .9, .9), isFalse);
      }
      expect(
        (await analyzePhotos(document, 31)).candidates.single.coverage,
        isNull,
      );
      final cropped = (await analyzePhotos(
        document,
        32,
      )).candidates.single.coverage!;
      expect(cropped.covers(.05, .1, .2, .9), isFalse);
      expect(cropped.covers(.4, .1, .9, .9), isTrue);
      for (final number in [14, 15, 28, 29]) {
        expect(
          (await analyzePhotos(
            document,
            number,
          )).candidates.single.classification,
          isNull,
        );
      }
    },
  );

  test('nonzero preview includes fractional alpha without changing panel eligibility or anchors', () async {
    final result = await analyzePhotos(document, 27);
    final c = result.candidates.single;
    final key = PhotoOverrides.target(document.pages[26], c);
    expect(c.reason, 'likely-photo');
    expect(key, isNotNull);
    final strict = c.renderingCoverage()!;
    final inclusive = c.renderingCoverage(includeTranslucent: true)!;
    expect(strict.covers(.32, .4, .35, .6), isFalse);
    expect(inclusive.covers(.32, .4, .35, .6), isTrue);
    expect(
      inclusive.covers(.4, .4, .6, .6),
      isFalse,
      reason: 'Fully transparent holes remain outside the preview mask',
    );
    expect(inclusive.fraction, greaterThan(strict.fraction));
    expect(inclusive.width, strict.width);
    expect(inclusive.height, strict.height);
    // Selection of rendering coverage must not replace the strict identity.
    expect(PhotoOverrides.target(document.pages[26], c), key);
    final strictOnly = PhotoCandidate(
      c.objectIndex,
      c.reason,
      region: c.region,
      classification: c.classification,
      sampleHash: c.sampleHash,
      coverage: c.coverage,
    );
    expect(PhotoOverrides.target(document.pages[26], strictOnly), key);
    for (final page in [1, 12]) {
      final c = (await analyzePhotos(document, page)).candidates.single;
      expect(
        c.translucentCoverage,
        isNull,
        reason:
            'Opaque rectangles and binary masks need no second retained map',
      );
      expect(c.renderingCoverage(includeTranslucent: true), same(c.coverage));
    }
    for (final page in [14, 15, 28, 29]) {
      final c = (await analyzePhotos(document, page)).candidates.single;
      expect(
        PhotoOverrides.target(document.pages[page - 1], c),
        isNull,
        reason: 'Preview does not admit Form transparency or fully translucent images',
      );
    }
  });

  test('nested inspection leaves page pixels and text unchanged', () async {
    for (final number in [1, 4, 5, 11, 14]) {
      final page = document.pages[number - 1];
      final before = (await page.render(
        fullWidth: page.width,
        fullHeight: page.height,
      ))!;
      final text = await page.loadText();
      try {
        await analyzePhotos(document, number);
        final after = (await page.render(
          fullWidth: page.width,
          fullHeight: page.height,
        ))!;
        try {
          expect(after.pixels, before.pixels);
          expect((await page.loadText())?.fullText, text?.fullText);
        } finally {
          after.dispose();
        }
      } finally {
        before.dispose();
      }
    }
  });

  test('dense masked figures finish every candidate within the coverage memory bound', () async {
    PhotoPageAnalysis? result;
    var decoded = 0;
    do {
      result = await analyzePhotoBatch(
        document,
        38,
        previous: result,
        maxImages: 3,
      );
      decoded += result.batchDecodedImages;
      expect(result.batchDecodedImages, lessThanOrEqualTo(3));
      final bytes = result.candidates.fold<int>(
        0,
        (n, c) => n + (c.coverage?.bits.length ?? 0),
      );
      expect(bytes, lessThanOrEqualTo(512 * 1024));
      final previewBytes = result.candidates.fold<int>(
        0,
        (n, c) => n + (c.translucentCoverage?.bits.length ?? 0),
      );
      expect(bytes + previewBytes, lessThanOrEqualTo(1024 * 1024));
    } while (!result.isComplete);
    expect(decoded, 100);
    expect(result.regions.length, 100);
    expect(result.candidates.every((c) => c.coverage != null), isTrue);
    expect(
      result.candidates.first.coverage!.bits.length,
      greaterThan(4096),
      reason: 'Exercise the shared page budget, not only tiny masks',
    );
  });
}
