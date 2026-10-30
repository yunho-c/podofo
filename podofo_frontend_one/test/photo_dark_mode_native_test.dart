import 'dart:convert';
import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:ui';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:pdfium_dart/pdfium_dart.dart';
import 'package:podofo_one/src/dark_mode/photo_analysis.dart';
import 'package:podofo_one/src/dark_mode/photo_geometry.dart';
import 'package:podofo_one/src/widgets/components/pdf_page_layout.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PdfDocument document;
  PdfDocument? opened;
  setUpAll(() async {
    await pdfrxInitialize();
    document = await PdfDocument.openFile(
      'test/fixtures/photo_dark_mode/mixed.pdf',
    );
    opened = document;
  });
  tearDownAll(() async {
    await opened?.dispose();
    await PdfrxEntryFunctions.instance.stopBackgroundWorker();
  });

  test('real PDF objects: mixed content and conservative fallback cases', () async {
    final manifest = jsonDecode(
      File('test/fixtures/photo_dark_mode/manifest.json').readAsStringSync(),
    );
    for (final spec in manifest['pages']) {
      final result = await analyzePhotos(document, spec['page']);
      expect(
        result.regions.length,
        spec['expectedPhotos'],
        reason:
            '${spec['name']}: ${result.fallback}, ${result.candidates.map((c) => c.reason)}',
      );
      if (spec['name'] == 'clip-alpha-form-skew') {
        expect(
          result.candidates.map((c) => c.reason),
          containsAll(['transparency', 'non-rectangular-transform']),
        );
      }
    }
  });

  test('crop, every quarter-turn, scale and spread offsets agree with PDFium PageToDevice', () async {
    final layout = layoutTwoPages(
      document.pages,
      const PdfViewerParams(margin: 11),
    );
    for (var number = 1; number <= 5; number++) {
      final result = await analyzePhotos(document, number);
      final region = result.regions.single;
      final page = document.pages[number - 1];
      final size = Size(page.width, page.height);
      final normalized = photoViewportRect(
        region,
        page,
        Offset.zero & size,
        Offset.zero & size,
      );
      final expected = await document.useNativeDocumentHandle((handle) {
        final api = getPdfium(modulePath: Pdfrx.pdfiumModulePath);
        final native = api.FPDF_LoadPage(
          Pointer<fpdf_document_t__>.fromAddress(handle),
          number - 1,
        );
        try {
          return using((arena) {
            final box = arena<FS_RECTF>();
            final x = arena<Int>();
            final y = arena<Int>();
            api.FPDF_GetPageBoundingBox(native, box);
            Offset convert(double px, double py) {
              expect(
                api.FPDF_PageToDevice(
                  native,
                  0,
                  0,
                  (page.width * 10).round(),
                  (page.height * 10).round(),
                  0,
                  px + box.ref.left,
                  py + box.ref.bottom,
                  x,
                  y,
                ),
                1,
              );
              return Offset(
                x.value / (page.width * 10),
                y.value / (page.height * 10),
              );
            }

            return Rect.fromPoints(
              convert(region.left, region.top),
              convert(region.right, region.bottom),
            );
          });
        } finally {
          api.FPDF_ClosePage(native);
        }
      });
      _closeRect(normalized, expected);
      final placed = layout.pageLayouts[number - 1];
      final viewport = Rect.fromLTWH(
        placed.left - 12,
        placed.top - 23,
        placed.width * 1.7,
        placed.height * 1.7,
      );
      final mapped = photoViewportRect(region, page, placed, viewport);
      _closeRect(
        mapped,
        Rect.fromLTRB(
          (expected.left * placed.width + 12) / viewport.width,
          (expected.top * placed.height + 23) / viewport.height,
          (expected.right * placed.width + 12) / viewport.width,
          (expected.bottom * placed.height + 23) / viewport.height,
        ),
      );
    }
  });

  test(
    'diagnostics retain rejected raster bounds, stats, Forms and budget skips',
    () async {
      final mixed = await analyzePhotos(document, 1);
      final accepted = mixed.candidates.singleWhere(
        (c) => c.reason == 'likely-photo',
      );
      expect(identical(accepted.region, mixed.regions.single), isTrue);
      expect(
        mixed.candidates.where((c) => c.reason != 'likely-photo'),
        isNotEmpty,
      );
      final gray = await analyzePhotos(document, 10);
      final rejected = gray.candidates.single;
      expect(rejected.reason, 'limited-palette');
      expect(rejected.classification!.colors, lessThan(90));
      expect(rejected.region.left, 20);
      expect(rejected.region.bottom, 200);
      expect(rejected.region.right, 180);
      expect(rejected.region.top, 360);
      final complex = await analyzePhotos(document, 8);
      final form = complex.candidates.singleWhere((c) => c.objectId == '2/0');
      expect(form.reason, 'likely-photo');
      expect(form.objectPath, [2, 0]);
      expect(form.region.left, 10);
      expect(form.region.bottom, 20);
      expect(form.region.right, 130);
      expect(form.region.top, 140);
      final budget = await analyzePhotos(document, 12);
      expect(budget.fallback, isNull);
      expect(budget.isComplete, isTrue);
      expect(budget.candidates, hasLength(25));
      expect(
        budget.candidates.every((c) => c.reason == 'small-or-outside-page'),
        isTrue,
      );
      expect(budget.candidates.every((c) => c.region.area == 25), isTrue);
      expect(budget.regions, isEmpty);
    },
  );

  test('read-only analysis leaves PDF rendering, text, and annotation count intact', () async {
    final page = document.pages[10];
    final before = await page.render(
      fullWidth: page.width,
      fullHeight: page.height,
    );
    final text = await page.loadText();
    await analyzePhotos(document, 11);
    final after = await page.render(
      fullWidth: page.width,
      fullHeight: page.height,
    );
    expect(after!.pixels, before!.pixels);
    expect((await page.loadText())?.fullText, text?.fullText);
    before.dispose();
    after.dispose();
    await document.useNativeDocumentHandle((handle) {
      final api = getPdfium(modulePath: Pdfrx.pdfiumModulePath);
      final native = api.FPDF_LoadPage(
        Pointer<fpdf_document_t__>.fromAddress(handle),
        10,
      );
      try {
        expect(api.FPDFPage_GetAnnotCount(native), 1);
      } finally {
        api.FPDF_ClosePage(native);
      }
    });
  });
}

void _closeRect(Rect actual, Rect expected) {
  expect(actual.left, closeTo(expected.left, .001));
  expect(actual.top, closeTo(expected.top, .001));
  expect(actual.right, closeTo(expected.right, .001));
  expect(actual.bottom, closeTo(expected.bottom, .001));
}
