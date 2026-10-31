import 'dart:ui';

import '../narration/source_map.dart';

class PreviewTextPage {
  PreviewTextPage(this.snapshot, List<Rect> boxes)
    : boxes = List.unmodifiable(boxes);
  final PdfTextSnapshot snapshot;
  final List<Rect> boxes;
  // UTF-16 plus both raw and displayed four-double rectangles; not total heap.
  int get accountedBytes =>
      snapshot.text.length * 2 + (snapshot.boxes.length + boxes.length) * 32;
}

class PreviewTextSpan {
  PreviewTextSpan(this.start, this.end, this.text, List<Rect> boxes)
    : boxes = List.unmodifiable(boxes);
  final int start, end;
  final String text;
  final List<Rect> boxes;
}

class LinkSourceText {
  LinkSourceText(
    List<PreviewTextSpan> spans,
    this.before,
    this.after,
    this.truncated,
  ) : spans = List.unmodifiable(spans);
  final List<PreviewTextSpan> spans;
  final String before, after;
  final bool truncated;
}

LinkSourceText sourceLinkText(PreviewTextPage page, List<Rect> links) {
  final text = page.snapshot.text;
  final hits = <int>[];
  var truncated = false;
  for (var i = 0; i < page.boxes.length; i++) {
    if (!page.boxes[i].isEmpty && links.any((r) => r.overlaps(page.boxes[i]))) {
      // PDFium may give spaces/newlines empty boxes. Retain whitespace between
      // selected glyphs so author/year labels preserve their original text.
      if (hits.isNotEmpty &&
          hits.last + 1 < i &&
          text.substring(hits.last + 1, i).trim().isEmpty) {
        final gapStart = hits.last + 1;
        for (var j = gapStart; j < i && hits.length < 2048; j++) {
          hits.add(j);
        }
      }
      if (hits.length == 2048) {
        truncated = true;
        break;
      }
      hits.add(i);
    }
  }
  bool low(int i) =>
      i < text.length &&
      text.codeUnitAt(i) >= 0xdc00 &&
      text.codeUnitAt(i) <= 0xdfff;
  // Never return half of a surrogate pair at the extraction budget boundary.
  if (truncated && hits.isNotEmpty && low(hits.last + 1)) hits.removeLast();
  final spans = <PreviewTextSpan>[];
  for (var i = 0; i < hits.length;) {
    final start = hits[i];
    var end = start + 1;
    while (++i < hits.length && hits[i] == end) {
      end++;
    }
    spans.add(
      PreviewTextSpan(
        start,
        end,
        text.substring(start, end),
        page.boxes.sublist(start, end),
      ),
    );
  }
  if (spans.isEmpty) return LinkSourceText([], '', '', truncated);
  final first = spans.first.start, last = spans.last.end;
  var before = (first - 256).clamp(0, text.length),
      after = (last + 256).clamp(0, text.length);
  if (low(before)) before++;
  if (low(after)) after--;
  return LinkSourceText(
    spans,
    text.substring(before, first),
    text.substring(last, after),
    truncated,
  );
}
