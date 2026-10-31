import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:pdfium_dart/pdfium_dart.dart';

import '../editing/editable_pdf_document.dart';
import '../editing/pdfium_document_task.dart';

bool get fractionalPageRenderingSupported => Platform.isMacOS;

/// Main viewport renderer for PoDoFo sessions on macOS. The editable document
/// pins its native backing generation until the worker returns; copied pixels
/// outlive the lease.
/// Other documents/platforms and interactive forms keep the stock renderer.
Future<ui.Image?> renderFractionalPage(
  PdfPage page,
  PdfViewportRenderRequest request,
) async {
  if (!fractionalPageRenderingSupported ||
      page.document is! EditablePdfDocument ||
      request.cancellationToken.isCanceled) {
    return null;
  }
  if (request.width <= 0 ||
      request.height <= 0 ||
      !request.scaleX.isFinite ||
      !request.scaleY.isFinite ||
      request.scaleX <= 0 ||
      request.scaleY <= 0 ||
      !request.pageLeft.isFinite ||
      !request.pageTop.isFinite) {
    throw ArgumentError('Invalid fractional viewport geometry');
  }
  final pixels = await pdfiumDocumentTask(page.document, _rasterize, (
    module: Pdfrx.pdfiumModulePath,
    page: page.pageNumber,
    width: request.width,
    height: request.height,
    scaleX: request.scaleX,
    scaleY: request.scaleY,
    left: request.pageLeft,
    top: request.pageTop,
    flags: request.flags,
    annotations:
        request.annotationRenderingMode != PdfAnnotationRenderingMode.none,
  ));
  // Native rendering itself is synchronous on the PDFium worker, like the
  // existing path. Cancellation discards results before decoding/publishing.
  if (pixels == null || request.cancellationToken.isCanceled) return null;
  final buffer = await ui.ImmutableBuffer.fromUint8List(pixels);
  try {
    final descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: request.width,
      height: request.height,
      pixelFormat: ui.PixelFormat.bgra8888,
    );
    try {
      final codec = await descriptor.instantiateCodec();
      try {
        final image = (await codec.getNextFrame()).image;
        if (request.cancellationToken.isCanceled) {
          image.dispose();
          return null;
        }
        return image;
      } finally {
        codec.dispose();
      }
    } finally {
      descriptor.dispose();
    }
  } finally {
    buffer.dispose();
  }
}

typedef _Raster = ({
  String? module,
  int page,
  int width,
  int height,
  double scaleX,
  double scaleY,
  double left,
  double top,
  int flags,
  bool annotations,
});

Uint8List? _rasterize(int handle, _Raster r) {
  final api = getPdfium(modulePath: r.module);
  final document = Pointer<fpdf_document_t__>.fromAddress(handle);
  // FPDF_FFLDraw only offers an integer transform. Until forms have their own
  // matched-transform path, fall back for the entire document rather than omit
  // their appearances or mix two coordinate systems on one page.
  if (api.FPDF_GetFormType(document) != FORMTYPE_NONE) return null;
  final page = api.FPDF_LoadPage(document, r.page - 1);
  if (page == nullptr) throw StateError('Cannot load page ${r.page}');
  try {
    return using((arena) {
      final pixels = arena<Uint8>(r.width * r.height * 4);
      final bitmap = api.FPDFBitmap_CreateEx(
        r.width,
        r.height,
        FPDFBitmap_BGRA,
        pixels.cast(),
        r.width * 4,
      );
      if (bitmap == nullptr) {
        throw StateError('Cannot allocate viewport bitmap');
      }
      try {
        api.FPDFBitmap_FillRect(bitmap, 0, 0, r.width, r.height, 0xffffffff);
        final matrix = arena<FS_MATRIX>();
        matrix.ref
          ..a = r.scaleX
          ..b = 0
          ..c = 0
          ..d = r.scaleY
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
          (r.flags & 0xffff) | (r.annotations ? FPDF_ANNOT : 0),
        );
        return Uint8List.fromList(pixels.asTypedList(r.width * r.height * 4));
      } finally {
        api.FPDFBitmap_Destroy(bitmap);
      }
    });
  } finally {
    api.FPDF_ClosePage(page);
  }
}
