import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:pdfium_dart/pdfium_dart.dart';
import 'package:podofo_one/src/editing/pdfium_document_task.dart';

typedef RasterRequest = ({
  String module,
  int page,
  int width,
  int height,
  double scale,
  double left,
  double top,
});

/// Render directly into the final output grid. PDFium supplies its intrinsic
/// crop/rotation/page-to-top-left transform before applying this matrix.
Future<Uint8List> referencePixels(
  PdfDocument document,
  RasterRequest request,
) => pdfiumDocumentTask(document, _render, request);

Uint8List _render(int handle, RasterRequest r) {
  final api = getPdfium(modulePath: r.module);
  final document = Pointer<fpdf_document_t__>.fromAddress(handle);
  if (api.FPDF_GetFormType(document) != FORMTYPE_NONE) {
    throw UnsupportedError(
      'Interactive forms are outside this harness version.',
    );
  }
  final page = api.FPDF_LoadPage(document, r.page - 1);
  if (page == nullptr) throw StateError('PDFium could not load page ${r.page}');
  try {
    return using((arena) {
      final buffer = arena<Uint8>(r.width * r.height * 4);
      final bitmap = api.FPDFBitmap_CreateEx(
        r.width,
        r.height,
        FPDFBitmap_BGRA,
        buffer.cast(),
        r.width * 4,
      );
      if (bitmap == nullptr) {
        throw StateError('PDFium bitmap allocation failed');
      }
      try {
        api.FPDFBitmap_FillRect(bitmap, 0, 0, r.width, r.height, 0xffffffff);
        final matrix = arena<FS_MATRIX>();
        matrix.ref
          ..a = r.scale
          ..b = 0
          ..c = 0
          ..d = r.scale
          ..e = r.left
          ..f = r.top;
        final clip = arena<FS_RECTF>();
        clip.ref
          ..left = 0
          ..top = 0
          ..right = r.width.toDouble()
          ..bottom = r.height.toDouble();
        api.FPDF_RenderPageBitmapWithMatrix(
          bitmap,
          page,
          matrix,
          clip,
          FPDF_ANNOT | FPDF_RENDER_LIMITEDIMAGECACHE,
        );
        // Own the copy before the worker releases the native buffer; convert
        // explicitly so both captures use opaque, unassociated RGBA bytes.
        final bytes = Uint8List.fromList(
          buffer.asTypedList(r.width * r.height * 4),
        );
        for (var i = 0; i < bytes.length; i += 4) {
          final blue = bytes[i];
          bytes[i] = bytes[i + 2];
          bytes[i + 2] = blue;
        }
        return bytes;
      } finally {
        api.FPDFBitmap_Destroy(bitmap);
      }
    });
  } finally {
    api.FPDF_ClosePage(page);
  }
}

/// The content is identical on four pages; intrinsic crop/rotation differ.
/// Geometry and region labels are in the unrotated 612x792 page's top-left axes.
const fixtureRegions = <String, List<double>>{
  'text': [140, 260, 340, 135],
  'lines': [140, 410, 340, 90],
  'patches': [140, 520, 340, 35],
};

Future<void> createFixture(
  String output,
  String module,
  String fontPath,
) async {
  final document = await PdfDocument.createNew(
    sourceName: 'render-quality-fixture',
  );
  try {
    await pdfiumDocumentTask(document, _populate, (
      module: module,
      font: File(fontPath).readAsBytesSync(),
    ));
    await document.reloadPages();
    // PDFium injects a clock-derived creation date and random trailer IDs.
    // Normalize only these generated-fixture fields, preserving byte offsets.
    final encoded = latin1.decode(await document.encodePdf());
    final stable = encoded
        .replaceAllMapped(
          RegExp(r'/(CreationDate|ModDate)\(D:\d{14}\)'),
          (m) => '/${m[1]}(D:20000101000000)',
        )
        .replaceAllMapped(
          RegExp(r'/ID\s*\[<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>\]'),
          (m) => m[0]!
              .replaceAll(m[1]!, '0' * m[1]!.length)
              .replaceAll(m[2]!, '0' * m[2]!.length),
        );
    File(output).writeAsBytesSync(latin1.encode(stable));
  } finally {
    await document.dispose();
  }
}

void _populate(int handle, ({String module, Uint8List font}) input) {
  final api = getPdfium(modulePath: input.module);
  final document = Pointer<fpdf_document_t__>.fromAddress(handle);
  using((arena) {
    final data = arena<Uint8>(input.font.length);
    data.asTypedList(input.font.length).setAll(0, input.font);
    final font = api.FPDFText_LoadFont(
      document,
      data,
      input.font.length,
      FPDF_FONT_TRUETYPE,
      1,
    );
    if (font == nullptr) throw StateError('Cannot embed fixture font');
    try {
      for (var index = 0; index < 4; index++) {
        final page = api.FPDFPage_New(document, index, 612, 792);
        if (page == nullptr) throw StateError('Cannot create fixture page');
        try {
          for (var line = 0; line < 6; line++) {
            final size = [6.0, 8.0, 10.0, 12.0, 16.0, 20.0][line];
            final object = api.FPDFPageObj_CreateTextObj(document, font, size);
            if (object == nullptr) {
              throw StateError('Cannot create text object');
            }
            final text = '${size.toInt()} pt: Quality ffi Il1 0O 0123456789';
            if (api.FPDFText_SetText(
                  object,
                  text.toNativeUtf16(allocator: arena).cast(),
                ) ==
                0) {
              api.FPDFPageObj_Destroy(object);
              throw StateError('Cannot set fixture text');
            }
            api.FPDFPageObj_Transform(object, 1, 0, 0, 1, 145, 520 - line * 23);
            api.FPDFPage_InsertObject(page, object);
          }
          for (var line = 0; line < 5; line++) {
            final y = 370.0 - line * 14;
            final path = api.FPDFPageObj_CreateNewPath(145, y);
            api.FPDFPath_LineTo(path, 300, y);
            api.FPDFPath_BezierTo(path, 330, y + 12, 380, y - 12, 470, y);
            api.FPDFPageObj_SetStrokeWidth(
              path,
              [.15, .25, .5, 1.0, 2.0][line],
            );
            api.FPDFPageObj_SetStrokeColor(path, 0, 0, 0, 255);
            api.FPDFPath_SetDrawMode(path, FPDF_FILLMODE_NONE, 1);
            api.FPDFPage_InsertObject(page, path);
          }
          for (var patch = 0; patch < 8; patch++) {
            final object = api.FPDFPageObj_CreateNewRect(
              145 + patch * 40,
              240,
              30,
              25,
            );
            final gray = (patch * 255 / 7).round();
            api.FPDFPageObj_SetFillColor(object, gray, gray, gray, 255);
            api.FPDFPath_SetDrawMode(object, FPDF_FILLMODE_WINDING, 0);
            api.FPDFPage_InsertObject(page, object);
          }
          // Asymmetric marks expose a flipped, translated, or twice-rotated reference.
          for (final mark in [
            (40.0, 740.0, 255, 0, 0),
            (550.0, 60.0, 0, 0, 255),
          ]) {
            final object = api.FPDFPageObj_CreateNewRect(
              mark.$1,
              mark.$2,
              12,
              8,
            );
            api.FPDFPageObj_SetFillColor(
              object,
              mark.$3,
              mark.$4,
              mark.$5,
              255,
            );
            api.FPDFPath_SetDrawMode(object, FPDF_FILLMODE_WINDING, 0);
            api.FPDFPage_InsertObject(page, object);
          }
          if (index >= 2) api.FPDFPage_SetCropBox(page, 20, 30, 592, 762);
          api.FPDFPage_SetRotation(page, index);
          if (api.FPDFPage_GenerateContent(page) == 0) {
            throw StateError('Cannot generate fixture page');
          }
        } finally {
          api.FPDF_ClosePage(page);
        }
      }
    } finally {
      api.FPDFFont_Close(font);
    }
  });
}
