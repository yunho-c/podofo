import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:pdfium_dart/pdfium_dart.dart';
import 'package:podofo_one/src/dark_mode/photo_analysis.dart';

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

  test('intrinsic masks evade HasTransparency but are not preserved', () async {
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
      expect(result.candidates.single.reason, 'mask-or-transparency');
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
}
