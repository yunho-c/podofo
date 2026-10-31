import 'dart:ffi';
import 'dart:ui';

import 'package:ffi/ffi.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:pdfium_dart/pdfium_dart.dart';

import 'link_target.dart';

Future<PdfRect?> previewPageBounds(PdfDocument document, int pageNumber) async {
  return document.useNativeDocumentHandle((handle) {
    final api = getPdfium(modulePath: Pdfrx.pdfiumModulePath);
    final native = api.FPDF_LoadPage(
      Pointer<fpdf_document_t__>.fromAddress(handle),
      pageNumber - 1,
    );
    if (native == nullptr) return null;
    try {
      return using((arena) {
        final rect = arena<FS_RECTF>();
        if (api.FPDF_GetPageBoundingBox(native, rect) == 0) return null;
        return PdfRect(
          rect.ref.left,
          rect.ref.top,
          rect.ref.right,
          rect.ref.bottom,
        );
      });
    } finally {
      api.FPDF_ClosePage(native);
    }
  });
}

/// Raw PDF destinations include the CropBox origin; pdfrx text/link boxes do not.
Rect previewRectToPage(PdfPage page, PdfRect bounds, PdfRect raw) =>
    raw.translate(-bounds.left, -bounds.bottom).toRect(page: page);

PreviewDestination? normalizePreviewDestination(
  PdfPage page,
  PdfDest dest,
  PdfRect bounds,
) {
  if (![
        page.width,
        page.height,
        bounds.width,
        bounds.height,
      ].every((v) => v.isFinite && v > 0) ||
      ![
        bounds.left,
        bounds.top,
        bounds.right,
        bounds.bottom,
      ].every((v) => v.isFinite)) {
    return null;
  }
  final p = dest.params ?? const <double?>[];
  if (p.any((v) => v != null && !v.isFinite)) return null;
  double? at(int i) => i < p.length ? p[i] : null;
  double? left, top;
  Rect? area;
  switch (dest.command) {
    case PdfDestCommand.xyz:
      left = at(0);
      top = at(1);
    case PdfDestCommand.fitR:
      if (p.length != 4 ||
          p.any((v) => v == null) ||
          p[0]! >= p[2]! ||
          p[1]! >= p[3]!) {
        return null;
      }
      area = previewRectToPage(
        page,
        bounds,
        PdfRect(p[0]!, p[3]!, p[2]!, p[1]!),
      ).intersect(Offset.zero & page.size);
      if (area.isEmpty) return null;
    // GetView cannot reliably distinguish absent axes for these commands.
    // They remain contextual and supply no semantic coordinate evidence in M1.
    case PdfDestCommand.fitH:
    case PdfDestCommand.fitBH:
    case PdfDestCommand.fitV:
    case PdfDestCommand.fitBV:
    case PdfDestCommand.fit:
    case PdfDestCommand.fitB:
      break;
    case PdfDestCommand.unknown:
      return null;
  }
  final point = previewRectToPage(
    page,
    bounds,
    PdfRect(
      left ?? bounds.left,
      top ?? bounds.top,
      left ?? bounds.left,
      top ?? bounds.top,
    ),
  ).center;
  final odd = page.rotation.index.isOdd;
  return PreviewDestination(
    page: dest.pageNumber,
    pageSize: page.size,
    area: area,
    x: (odd ? top : left) == null ? null : point.dx,
    y: (odd ? left : top) == null ? null : point.dy,
  );
}
