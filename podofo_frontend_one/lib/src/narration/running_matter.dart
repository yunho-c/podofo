import 'package:pdfrx/pdfrx.dart';

import 'pdf_text_repository.dart';

/// A narrow margin line is excluded only when another nearby page confirms it.
class MarginLine {
  const MarginLine(this.start, this.end, this.key, this.top, this.y);
  final int start, end;
  final String key;
  final bool top;
  final double y;

  bool matches(MarginLine other) =>
      top == other.top && key == other.key && (y - other.y).abs() < .025;
}

List<MarginLine> marginLines(ExtractedPaperPage page) {
  if (!page.height.isFinite || page.height <= 0) return const [];
  final result = <MarginLine>[];
  for (final match in RegExp(r'[^\r\n]+').allMatches(page.text.text)) {
    final text = match.group(0)!.trim();
    if (text.isEmpty || text.length > 140) continue;
    final boxes = page.text.boxes
        .sublist(match.start, match.end)
        .where(
          (b) =>
              b.width > 0 &&
              b.height > 0 &&
              [b.left, b.top, b.right, b.bottom].every((v) => v.isFinite),
        )
        .toList();
    if (boxes.isEmpty) continue;
    final bounds = boxes.boundingRect();
    var key = text.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    final number = RegExp(r'^(?:(?:page|p\.)\s*)?(\d+)(?:\s*(?:of|/)\s*\d+)?$')
        .firstMatch(key);
    // Standalone page numbers often sit inside a one-inch footer. Require the
    // same numbering offset on neighboring pages, rather than treating repeated
    // chart tick values as pagination.
    final margin = number == null ? .07 : .10;
    final top = bounds.bottom >= page.height * (1 - margin);
    if (!top && bounds.top > page.height * margin) continue;
    // A tall region is not a single running header/footer line.
    if (bounds.height > page.height * .035) continue;
    // Only a complete page-number line is generalized; equation/citation digits
    // and numbered titles are never stripped from an arbitrary line.
    if (number != null) {
      final value = int.tryParse(number[1]!);
      if (value == null) continue;
      key = '<page-number:${value - page.text.page}>';
    }
    result.add(
      MarginLine(
        match.start,
        match.end,
        key,
        top,
        bounds.center.y / page.height,
      ),
    );
    if (result.length > 64) return const [];
  }
  return result;
}
