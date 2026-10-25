import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:pdfium_dart/pdfium_dart.dart';

import '../editing/pdfium_document_task.dart';

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
          .enumerateSelectionRects()
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
  ) => pdfiumDocumentTask(document, _listPage, pageNumber);

  static List<SavedHighlight> _listPage(int handle, int pageNumber) {
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
          if (api.FPDFAnnot_GetFlags(annotation) & FPDF_ANNOT_FLAG_HIDDEN !=
                  0 ||
              api.FPDFAnnot_GetSubtype(annotation) != FPDF_ANNOT_HIGHLIGHT) {
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
  }
}
