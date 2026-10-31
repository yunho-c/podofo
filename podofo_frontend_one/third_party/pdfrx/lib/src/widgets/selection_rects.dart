import 'dart:math';

import 'package:pdfrx_engine/pdfrx_engine.dart';

/// Shared selection/highlight geometry; keeps logical text ranges intact.
extension PdfSelectionPaintRects on PdfPageTextRange {
  /// Enumerate rectangles for painting or annotating this selection in PDF
  /// page coordinates (relative to the unrotated page's bounding box).
  ///
  /// Consecutive fragments on the same line and in the same known writing
  /// direction are joined across word-sized gaps. Line breaks, direction
  /// changes, and larger gaps (such as column gutters) keep regions separate.
  /// Partial first and last fragments retain their selected character bounds.
  ///
  /// This only changes visual geometry; [text], character indices, and
  /// [enumerateFragmentBoundingRects] are unchanged. Use the original character
  /// rectangles for hit testing.
  Iterable<PdfRect> enumerateSelectionRects() sync* {
    if (start >= end || pageText.fragments.isEmpty) return;

    PdfRect? bounds;
    PdfRect? lineBounds;
    PdfRect? lastWordBounds;
    PdfTextFragmentBoundingRect? previous;
    for (final fragment in enumerateFragmentBoundingRects()) {
      final rect = fragment.bounds;
      final selectedText = pageText.fullText.substring(fragment.start, fragment.end);
      final hasBreak = _selectionBreaks.hasMatch(selectedText);
      final isSpace = selectedText.trim().isEmpty;
      final continues =
          previous != null &&
          previous.end == fragment.start &&
          previous.direction == fragment.direction &&
          fragment.direction != PdfTextDirection.unknown;

      // A zero-width space can still connect logically adjacent words.
      if (continues && !hasBreak && isSpace && rect.isEmpty) {
        previous = fragment;
        continue;
      }

      if (bounds != null &&
          (!continues ||
              hasBreak ||
              rect.isEmpty ||
              !_onSameSelectionLine(lineBounds!, rect, fragment.direction) ||
              !_canJoinSelectionRects(lastWordBounds!, rect, fragment.direction))) {
        yield bounds;
        bounds = null;
      }
      if (rect.isEmpty) {
        previous = null;
        continue;
      }
      if (hasBreak) {
        yield rect;
        previous = null;
        continue;
      }

      if (bounds == null) {
        bounds = lineBounds = lastWordBounds = rect;
      } else {
        bounds = bounds.merge(rect);
        // Measure the entire word gap, not just what remains after a capped
        // space rectangle. Otherwise spaces could bridge a column gutter.
        if (!isSpace) lastWordBounds = rect;
      }
      previous = fragment;
    }
    if (bounds != null) yield bounds;
  }
}

final _selectionBreaks = RegExp(r'[\r\n\t\f\u2028\u2029]');

/// Compare against a fixed line band so successive offsets cannot join lines.
bool _onSameSelectionLine(PdfRect a, PdfRect b, PdfTextDirection direction) {
  final vertical = direction == PdfTextDirection.vrtl;
  final extent = vertical ? min(a.width, b.width) : min(a.height, b.height);
  final overlap = vertical ? min(a.right, b.right) - max(a.left, b.left) : min(a.top, b.top) - max(a.bottom, b.bottom);
  final centerDistance = vertical ? (a.center.x - b.center.x).abs() : (a.center.y - b.center.y).abs();
  return extent > 0 && overlap >= extent * 0.5 && centerDistance <= extent * 0.5;
}

/// Require forward progression and cap the full gap using the smaller font.
bool _canJoinSelectionRects(PdfRect a, PdfRect b, PdfTextDirection direction) {
  if (!_onSameSelectionLine(a, b, direction)) return false;
  final double gap;
  final double extent;
  switch (direction) {
    case PdfTextDirection.ltr:
      if (b.left < a.left || b.right < a.right) return false;
      gap = b.left - a.right;
      extent = min(a.height, b.height);
    case PdfTextDirection.rtl:
      if (b.right > a.right || b.left > a.left) return false;
      gap = a.left - b.right;
      extent = min(a.height, b.height);
    case PdfTextDirection.vrtl:
      if (b.top > a.top || b.bottom > a.bottom) return false;
      gap = a.bottom - b.top;
      extent = min(a.width, b.width);
    case PdfTextDirection.unknown:
      return false;
  }
  return gap <= extent * 1.5;
}
