import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:ui';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pdfrx/pdfrx.dart';
import 'package:pdfium_dart/pdfium_dart.dart';
import 'package:podofo_one/src/services/pdf_highlights.dart';
import 'package:podofo_one/src/services/pdf_session.dart';

import 'fixtures/spaced_text_pdf.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporary;
  setUpAll(() async {
    temporary = await Directory.systemTemp.createTemp('podofo-highlight-');
    await pdfrxInitialize(tmpPath: temporary.path);
  });
  tearDownAll(() async {
    await PdfrxEntryFunctions.instance.stopBackgroundWorker();
    await temporary.delete(recursive: true);
  });

  for (final rotation in [0, 90, 180, 270]) {
    test('saved highlight fills word gaps but not gutters at $rotation degrees', () async {
      final file = File('${temporary.path}/highlight-$rotation.pdf');
      await file.writeAsBytes(spacedTextPdf(cropped: true, rotation: rotation));
      final session = await PdfSession.open(file.path);
      late PdfPageTextRange range;
      late List<HighlightRegion> regions;
      // Extract from an unrotated copy to isolate persistence/rendering from
      // PDFium's rotation-sensitive extraction order. Coordinates are unrotated.
      final selectionDocument = await PdfDocument.openData(
        spacedTextPdf(cropped: true),
      );
      try {
        final text = await selectionDocument.pages.single.loadStructuredText();
        final start = text.fullText.indexOf('The') + 1;
        final end = text.fullText.indexOf('curve') + 3;
        range = PdfPageTextRange(pageText: text, start: start, end: end);
        expect(range.text, 'he vertical cur');
        regions = HighlightRegion.fromTextRanges([range], includeText: true);
        expect(regions.single.rects, hasLength(2));
        await session.highlight(regions, 0x66ffeb3b);
        await session.save();
      } finally {
        await selectionDocument.dispose();
        await session.close(discard: true);
      }

      final pdf = await PdfDocument.openFile(file.path);
      try {
        // Check stored quads and alpha, not just the in-memory selection shape.
        await pdf.useNativeDocumentHandle((handle) {
          final api = getPdfium(modulePath: Pdfrx.pdfiumModulePath);
          final page = api.FPDF_LoadPage(
            Pointer<fpdf_document_t__>.fromAddress(handle),
            0,
          );
          expect(page, isNot(nullptr));
          try {
            expect(api.FPDFPage_GetAnnotCount(page), 1);
            final annotation = api.FPDFPage_GetAnnot(page, 0);
            try {
              expect(api.FPDFAnnot_CountAttachmentPoints(annotation), 2);
              using((arena) {
                final box = arena<FS_RECTF>();
                expect(api.FPDF_GetPageBoundingBox(page, box), 1);
                final quad = arena<FS_QUADPOINTSF>();
                for (var i = 0; i < regions.single.rects.length; i++) {
                  expect(
                    api.FPDFAnnot_GetAttachmentPoints(annotation, i, quad),
                    1,
                  );
                  final rect = regions.single.rects[i];
                  expect(quad.ref.x1, closeTo(rect.left + box.ref.left, .001));
                  expect(quad.ref.y1, closeTo(rect.top + box.ref.bottom, .001));
                  expect(quad.ref.x4, closeTo(rect.right + box.ref.left, .001));
                  expect(
                    quad.ref.y4,
                    closeTo(rect.bottom + box.ref.bottom, .001),
                  );
                }
                // Rendering/saving can create an appearance stream, so inspect
                // the opacity dictionary entry rather than GetColor's AP-limited API.
                final alpha = arena<Float>();
                expect(
                  api.FPDFAnnot_GetNumberValue(
                    annotation,
                    'CA'.toNativeUtf8(allocator: arena).cast(),
                    alpha,
                  ),
                  1,
                );
                expect(alpha.value, closeTo(.4, .001));
              });
            } finally {
              api.FPDFPage_CloseAnnot(annotation);
            }
          } finally {
            api.FPDF_ClosePage(page);
          }
        });
        expect((await PdfHighlights.listPage(pdf, 1)).single.text, isEmpty);
        final page = pdf.pages.single;
        expect(page.rotation.index * 90, rotation);
        final render = (await page.render(
          fullWidth: page.width * 2,
          fullHeight: page.height * 2,
        ))!;
        try {
          final pixels = img.Image.fromBytes(
            width: render.width,
            height: render.height,
            bytes: render.pixels.buffer,
            order: img.ChannelOrder.bgra,
          );
          img.Pixel pixelAt(PdfPoint point) {
            final position = PdfRect(point.x, point.y, point.x, point.y)
                .toRect(
                  page: page,
                  scaledPageSize: Size(
                    render.width.toDouble(),
                    render.height.toDouble(),
                  ),
                )
                .center;
            return pixels.getPixel(position.dx.floor(), position.dy.floor());
          }

          final fragments = range.enumerateFragmentBoundingRects().toList();
          final space = fragments.firstWhere((f) => f.fragment.text == ' ');
          final vertical = fragments.firstWhere(
            (f) => f.fragment.text == 'vertical',
          );
          final curve = fragments.firstWhere((f) => f.fragment.text == 'curve');
          expect(space.bounds.right, lessThan(vertical.bounds.left - 1));
          final wordGap = pixelAt(
            PdfPoint(
              (space.bounds.right + vertical.bounds.left) / 2,
              vertical.bounds.center.y,
            ),
          );
          expect(wordGap.r, greaterThan(245));
          expect(wordGap.g, inInclusiveRange(240, 251));
          expect(wordGap.b, inInclusiveRange(170, 183));
          final gutter = pixelAt(
            PdfPoint(
              (vertical.bounds.right + curve.bounds.left) / 2,
              vertical.bounds.center.y,
            ),
          );
          expect([gutter.r, gutter.g, gutter.b], [255, 255, 255]);
          final artifacts = Directory('build/test-artifacts')
            ..createSync(recursive: true);
          File('${artifacts.path}/continuous-highlight-$rotation.png')
              .writeAsBytesSync(img.encodePng(pixels));
        } finally {
          render.dispose();
        }
      } finally {
        await pdf.dispose();
      }
    });
  }
}
