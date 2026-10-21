import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:pdfrx/pdfrx.dart';

/// A durable location in extracted page text, independent of annotations/paths.
class SourceAnchor {
  const SourceAnchor(
    this.page,
    this.offset,
    this.textHash, {
    this.contextBefore = '',
    this.contextAfter = '',
  });
  final int page, offset;
  final String textHash;
  final String contextBefore, contextAfter;

  SourceAnchor withContext(String text, int at) {
    RangeError.checkValueInInterval(at, 0, text.length, 'offset');
    bool low(int unit) => unit >= 0xdc00 && unit <= 0xdfff;
    if (at > 0 && at < text.length && low(text.codeUnitAt(at))) at--;
    var before = math.max(0, at - 32), after = math.min(text.length, at + 32);
    if (before > 0 && low(text.codeUnitAt(before))) before--;
    if (after < text.length && low(text.codeUnitAt(after))) after++;
    return SourceAnchor(
      page,
      offset,
      textHash,
      contextBefore: text.substring(before, at),
      contextAfter: text.substring(at, after),
    );
  }
}

/// No native page/document references survive extraction.
class PdfTextSnapshot {
  PdfTextSnapshot({
    required this.page,
    required this.text,
    required List<PdfRect> boxes,
  }) : boxes = List.unmodifiable(utf16Boxes(text, boxes)),
       textHash = sha256.convert(utf8.encode(text)).toString();

  factory PdfTextSnapshot.fromText(PdfPageText text) => PdfTextSnapshot(
    page: text.pageNumber,
    text: text.fullText,
    boxes: text.charRects,
  );
  final int page;
  final String text, textHash;
  final List<PdfRect> boxes;
  late final Set<String> intactWords = {
    for (final match in RegExp(r'[A-Za-z]+').allMatches(text))
      match.group(0)!.toLowerCase(),
  };

  String pdfiumHyphen(int offset) {
    final left = RegExp(r'[A-Za-z]+$')
        .firstMatch(text.substring(math.max(0, offset - 64), offset))
        ?.group(0);
    final right = RegExp(r'^[a-z]+')
        .firstMatch(
          text.substring(offset + 1, math.min(text.length, offset + 65)),
        )
        ?.group(0);
    return left != null &&
            right != null &&
            intactWords.contains('$left$right'.toLowerCase())
        ? ''
        : '-';
  }

  SourceAnchor anchor(int offset) =>
      SourceAnchor(page, offset, textHash).withContext(text, offset);

  /// PDFium emits one box per Unicode scalar; Dart ranges use UTF-16 units.
  /// Some engines already expand boxes, so accept both explicit representations.
  static List<PdfRect> utf16Boxes(String text, List<PdfRect> boxes) {
    if (boxes.length == text.length) return boxes;
    final runes = text.runes.toList();
    if (boxes.length != runes.length) {
      throw StateError(
        'This PDF has inconsistent text positions. Select another passage.',
      );
    }
    return [
      for (var i = 0; i < runes.length; i++) ...[
        boxes[i],
        if (runes[i] > 0xffff) boxes[i],
      ],
    ];
  }
}

/// Normalize PDFium's raw geometry before pdfrx's UTF-16 text formatter runs.
class NarrationPdfPage extends PdfPage {
  NarrationPdfPage(this.basePage);
  final PdfPage basePage;
  @override
  PdfDocument get document => basePage.document;
  @override
  int get pageNumber => basePage.pageNumber;
  @override
  double get width => basePage.width;
  @override
  double get height => basePage.height;
  @override
  PdfPageRotation get rotation => basePage.rotation;
  @override
  bool get isLoaded => basePage.isLoaded;
  @override
  PdfPageRenderCancellationToken createCancellationToken() =>
      basePage.createCancellationToken();
  @override
  Future<List<PdfLink>> loadLinks({
    bool compact = false,
    bool enableAutoLinkDetection = true,
  }) => basePage.loadLinks(
    compact: compact,
    enableAutoLinkDetection: enableAutoLinkDetection,
  );
  @override
  Future<PdfImage?> render({
    int x = 0,
    int y = 0,
    int? width,
    int? height,
    double? fullWidth,
    double? fullHeight,
    int? backgroundColor,
    PdfPageRotation? rotationOverride,
    PdfAnnotationRenderingMode annotationRenderingMode =
        PdfAnnotationRenderingMode.annotationAndForms,
    int flags = PdfPageRenderFlags.none,
    PdfPageRenderCancellationToken? cancellationToken,
  }) => basePage.render(
    x: x,
    y: y,
    width: width,
    height: height,
    fullWidth: fullWidth,
    fullHeight: fullHeight,
    backgroundColor: backgroundColor,
    rotationOverride: rotationOverride,
    annotationRenderingMode: annotationRenderingMode,
    flags: flags,
    cancellationToken: cancellationToken,
  );
  @override
  Future<PdfPageRawText?> loadText() async {
    final raw = await basePage.loadText();
    return raw == null
        ? null
        : PdfPageRawText(
            raw.fullText,
            PdfTextSnapshot.utf16Boxes(raw.fullText, raw.charRects),
          );
  }
}

class PdfTextSlice {
  const PdfTextSlice(
    this.page,
    this.start,
    this.end, {
    this.joinPrevious = false,
  });
  final PdfTextSnapshot page;
  final int start, end;
  final bool joinPrevious;
}

class SpokenSpan {
  const SpokenSpan(
    this.start,
    this.end,
    this.source,
    this.sourceEnd,
    this.boxes,
  );
  final int start, end, sourceEnd;
  final SourceAnchor source;
  final List<PdfRect> boxes;
}

/// Request text and its many-to-many mapping to the original PDF text.
class NarrationPassage {
  NarrationPassage(this.text, Iterable<SpokenSpan> spans)
    : spans = List.unmodifiable(spans);
  final String text;
  final List<SpokenSpan> spans;

  factory NarrationPassage.fromSlices(Iterable<PdfTextSlice> slices) {
    final output = StringBuffer();
    final spans = <SpokenSpan>[];
    var previousSpace = true;
    const ligatures = {
      'ﬀ': 'ff',
      'ﬁ': 'fi',
      'ﬂ': 'fl',
      'ﬃ': 'ffi',
      'ﬄ': 'ffl',
      'ﬅ': 'st',
      'ﬆ': 'st',
    };
    for (final slice in slices) {
      RangeError.checkValidRange(
        slice.start,
        slice.end,
        slice.page.text.length,
      );
      if (output.isNotEmpty && !previousSpace && !slice.joinPrevious) {
        output.write(' ');
        previousSpace = true;
      }
      var offset = slice.start;
      for (final rune
          in slice.page.text.substring(slice.start, slice.end).runes) {
        final original = String.fromCharCode(rune);
        final sourceEnd = offset + original.length;
        var spoken = ligatures[original] ?? original;
        // PDFium marks a joined line-end hyphen as U+0002. Keep the original
        // source unit/geometry; remove it only with intact-word evidence.
        if (rune == 2) spoken = slice.page.pdfiumHyphen(offset);
        final space = original.trim().isEmpty;
        if (space) spoken = previousSpace ? '' : ' ';
        // Soft hyphens and PDF NUL markers are not words. Literal hyphens remain.
        if (rune == 0xad || rune == 0 || rune == 0x200b) spoken = '';
        if (spoken.isNotEmpty) {
          final start = output.length;
          output.write(spoken);
          spans.add(
            SpokenSpan(
              start,
              output.length,
              SourceAnchor(slice.page.page, offset, slice.page.textHash),
              sourceEnd,
              List.unmodifiable(slice.page.boxes.sublist(offset, sourceEnd)),
            ),
          );
          previousSpace = space;
        }
        offset = sourceEnd;
      }
    }
    final text = output.toString().trimRight();
    return NarrationPassage(text, spans.where((s) => s.start < text.length));
  }

  SourceAnchor? anchorAt(int offset) {
    for (final span in spans) {
      if (span.end > offset) return span.source.withContext(text, span.start);
    }
    return spans.lastOrNull?.source.withContext(text, spans.last.start);
  }

  int? offsetOf(SourceAnchor anchor) {
    SpokenSpan? next;
    for (final span in spans) {
      if (span.source.page != anchor.page ||
          span.source.textHash != anchor.textHash) {
        continue;
      }
      if (span.source.offset <= anchor.offset &&
          span.sourceEnd > anchor.offset) {
        return span.start;
      }
      // Source order can differ from spoken order in a multi-column PDF.
      if (span.source.offset > anchor.offset &&
          (next == null || span.source.offset < next.source.offset)) {
        next = span;
      }
    }
    return next?.start;
  }

  NarrationPassage sliceFrom(int offset) {
    RangeError.checkValueInInterval(offset, 0, text.length, 'offset');
    if (offset > 0 &&
        offset < text.length &&
        text.codeUnitAt(offset) >= 0xdc00 &&
        text.codeUnitAt(offset) <= 0xdfff) {
      offset--; // Never split a surrogate pair.
    }
    return NarrationPassage(text.substring(offset), [
      for (final span in spans)
        if (span.end > offset)
          SpokenSpan(
            math.max(0, span.start - offset),
            span.end - offset,
            span.source,
            span.sourceEnd,
            span.boxes,
          ),
    ]);
  }

  List<PdfRect> rectangles(int page, int start, int end) {
    final rects = <PdfRect>[];
    for (final span in spans) {
      if (span.source.page != page || span.end <= start || span.start >= end) {
        continue;
      }
      for (final rect in span.boxes) {
        if (![
              rect.left,
              rect.top,
              rect.right,
              rect.bottom,
            ].every((v) => v.isFinite) ||
            rect.width <= 0 ||
            rect.height <= 0 ||
            rects.lastOrNull == rect) {
          continue;
        }
        final last = rects.lastOrNull;
        if (last != null &&
            (last.top - rect.top).abs() < 1 &&
            (last.bottom - rect.bottom).abs() < 1 &&
            rect.left >= last.left &&
            rect.left <= last.right + 4) {
          rects[rects.length - 1] = PdfRect(
            last.left,
            math.max(last.top, rect.top),
            math.max(last.right, rect.right),
            math.min(last.bottom, rect.bottom),
          );
        } else {
          rects.add(rect);
        }
      }
    }
    return rects;
  }
}
