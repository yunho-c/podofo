import 'dart:ffi';
import 'dart:math' as math;

import 'package:ffi/ffi.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:pdfium_dart/pdfium_dart.dart';

/// Coordinates from pdfrx are relative to the unrotated page's bounding box.
class HighlightRegion {
  const HighlightRegion(this.pageNumber, this.rects, {this.text = ''});
  final int pageNumber;
  final List<PdfRect> rects;
  final String text;

  /// Selection ranges may include empty pages and zero-area separator glyphs.
  static List<HighlightRegion> fromTextRanges(
    Iterable<PdfPageTextRange> ranges, {
    required bool includeText,
  }) {
    final result = <HighlightRegion>[];
    for (final range in ranges) {
      if (range.start >= range.end || range.pageText.fragments.isEmpty) {
        continue;
      }
      final rects = range
          .enumerateFragmentBoundingRects()
          .map((fragment) => fragment.bounds)
          .where(_hasUsableBounds)
          .toList();
      if (rects.isEmpty) continue;
      result.add(
        HighlightRegion(
          range.pageNumber,
          rects,
          text: includeText ? range.text : '',
        ),
      );
    }
    return result;
  }
}

bool _hasUsableBounds(PdfRect rect) =>
    [rect.left, rect.top, rect.right, rect.bottom].every((v) => v.isFinite) &&
    rect.width > 0 &&
    rect.height > 0;

typedef AddedHighlight = ({int pageNumber, int index});
typedef SavedHighlight = ({int pageNumber, int index, String text});

class PdfHighlights {
  static Future<List<SavedHighlight>> listPage(
    PdfDocument document,
    int pageNumber,
  ) => document.useNativeDocumentHandle((handle) {
    final api = getPdfium(modulePath: Pdfrx.pdfiumModulePath);
    final page = api.FPDF_LoadPage(
      Pointer<fpdf_document_t__>.fromAddress(handle),
      pageNumber - 1,
    );
    if (page == nullptr) throw StateError('Cannot read highlights.');
    try {
      final result = <SavedHighlight>[];
      for (var index = 0; index < api.FPDFPage_GetAnnotCount(page); index++) {
        final annotation = api.FPDFPage_GetAnnot(page, index);
        if (annotation == nullptr) continue;
        try {
          if (api.FPDFAnnot_GetSubtype(annotation) != FPDF_ANNOT_HIGHLIGHT) {
            continue;
          }
          final text = using((arena) {
            final key = 'Contents'.toNativeUtf8(allocator: arena).cast<Char>();
            final length = api.FPDFAnnot_GetStringValue(
              annotation,
              key,
              nullptr,
              0,
            );
            if (length < 2 || length > 65536) return '';
            final buffer = arena<Uint16>(length ~/ 2);
            api.FPDFAnnot_GetStringValue(
              annotation,
              key,
              buffer.cast(),
              length,
            );
            return buffer.cast<Utf16>().toDartString(length: length ~/ 2 - 1);
          });
          result.add((pageNumber: pageNumber, index: index, text: text));
        } finally {
          api.FPDFPage_CloseAnnot(annotation);
        }
      }
      return result;
    } finally {
      api.FPDF_ClosePage(page);
    }
  });

  static Future<List<AddedHighlight>> add(
    PdfDocument document,
    List<HighlightRegion> regions,
    int argb,
  ) async {
    if (document.permissions?.allowsModifyAnnotations == false) {
      throw StateError('This PDF does not allow annotation changes.');
    }
    if (regions.isEmpty ||
        regions.any(
          (r) =>
              r.rects.isEmpty ||
              r.pageNumber < 1 ||
              r.pageNumber > document.pages.length ||
              r.rects.any((rect) => !_hasUsableBounds(rect)),
        )) {
      throw ArgumentError('Invalid highlight bounds.');
    }
    final added = <AddedHighlight>[];
    await document.useNativeDocumentHandle((handle) {
      final api = getPdfium(modulePath: Pdfrx.pdfiumModulePath);
      final native = Pointer<fpdf_document_t__>.fromAddress(handle);
      if (api.FPDF_GetSignatureCount(native) > 0) {
        throw StateError(
          'Digitally signed PDFs are read-only. Open an unsigned copy to add highlights.',
        );
      }
      try {
        for (final region in regions) {
          final page = api.FPDF_LoadPage(native, region.pageNumber - 1);
          if (page == nullptr) throw StateError('Cannot load page.');
          try {
            final index = api.FPDFPage_GetAnnotCount(page);
            final annotation = api.FPDFPage_CreateAnnot(
              page,
              FPDF_ANNOT_HIGHLIGHT,
            );
            if (annotation == nullptr) {
              throw StateError('Cannot create highlight.');
            }
            added.add((pageNumber: region.pageNumber, index: index));
            try {
              using((arena) {
                final box = arena<FS_RECTF>();
                _check(api.FPDF_GetPageBoundingBox(page, box));
                final dx = box.ref.left, dy = box.ref.bottom;
                double left = double.infinity, bottom = double.infinity;
                double right = -double.infinity, top = -double.infinity;
                for (final rect in region.rects) {
                  final quad = arena<FS_QUADPOINTSF>();
                  quad.ref
                    ..x1 = rect.left + dx
                    ..y1 = rect.top + dy
                    ..x2 = rect.right + dx
                    ..y2 = rect.top + dy
                    ..x3 = rect.left + dx
                    ..y3 = rect.bottom + dy
                    ..x4 = rect.right + dx
                    ..y4 = rect.bottom + dy;
                  _check(
                    api.FPDFAnnot_AppendAttachmentPoints(annotation, quad),
                  );
                  left = math.min(left, rect.left + dx);
                  right = math.max(right, rect.right + dx);
                  bottom = math.min(bottom, rect.bottom + dy);
                  top = math.max(top, rect.top + dy);
                }
                box.ref
                  ..left = left
                  ..right = right
                  ..bottom = bottom
                  ..top = top;
                _check(api.FPDFAnnot_SetRect(annotation, box));
                _check(
                  api.FPDFAnnot_SetColor(
                    annotation,
                    FPDFANNOT_COLORTYPE.FPDFANNOT_COLORTYPE_Color,
                    (argb >> 16) & 255,
                    (argb >> 8) & 255,
                    argb & 255,
                    (argb >> 24) & 255,
                  ),
                );
                _check(
                  api.FPDFAnnot_SetFlags(annotation, FPDF_ANNOT_FLAG_PRINT),
                );
                _check(
                  api.FPDFAnnot_SetStringValue(
                    annotation,
                    'Contents'.toNativeUtf8(allocator: arena).cast(),
                    region.text.toNativeUtf16(allocator: arena).cast(),
                  ),
                );
                _check(
                  api.FPDFAnnot_SetStringValue(
                    annotation,
                    'T'.toNativeUtf8(allocator: arena).cast(),
                    'PoDoFo'.toNativeUtf16(allocator: arena).cast(),
                  ),
                );
              });
            } finally {
              api.FPDFPage_CloseAnnot(annotation);
            }
          } finally {
            api.FPDF_ClosePage(page);
          }
        }
      } catch (_) {
        _remove(api, native, added);
        rethrow;
      }
    });
    return added;
  }

  static Future<void> remove(
    PdfDocument document,
    List<AddedHighlight> added,
  ) async {
    await document.useNativeDocumentHandle((handle) {
      if (document.permissions?.allowsModifyAnnotations == false ||
          getPdfium(modulePath: Pdfrx.pdfiumModulePath).FPDF_GetSignatureCount(
                Pointer<fpdf_document_t__>.fromAddress(handle),
              ) >
              0) {
        throw StateError('This PDF does not allow annotation changes.');
      }
      _remove(
        getPdfium(modulePath: Pdfrx.pdfiumModulePath),
        Pointer<fpdf_document_t__>.fromAddress(handle),
        added,
      );
    });
  }

  static void _remove(
    PDFium api,
    FPDF_DOCUMENT document,
    List<AddedHighlight> added,
  ) {
    for (final item in added.reversed) {
      final page = api.FPDF_LoadPage(document, item.pageNumber - 1);
      if (page == nullptr) {
        throw StateError('Cannot load page to remove highlight.');
      }
      try {
        _check(api.FPDFPage_RemoveAnnot(page, item.index));
      } finally {
        api.FPDF_ClosePage(page);
      }
    }
  }

  static void _check(int result) {
    if (result == 0) throw StateError('PDFium could not update the highlight.');
  }
}
