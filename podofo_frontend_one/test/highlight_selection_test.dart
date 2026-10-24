import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:podofo_one/src/services/pdf_highlights.dart';

PdfPageTextRange textRange(
  int pageNumber,
  List<PdfRect> bounds, {
  String? content,
  int start = 0,
  int? end,
}) {
  final fragments = <PdfPageTextFragment>[];
  final text = PdfPageText(
    pageNumber: pageNumber,
    fullText: content ?? List.filled(bounds.length, 'x').join(),
    charRects: bounds,
    fragments: fragments,
  );
  for (var i = 0; i < bounds.length; i++) {
    fragments.add(
      PdfPageTextFragment(
        pageText: text,
        index: i,
        length: 1,
        bounds: bounds[i],
        charRects: [bounds[i]],
        direction: PdfTextDirection.ltr,
      ),
    );
  }
  return PdfPageTextRange(
    pageText: text,
    start: start,
    end: end ?? bounds.length,
  );
}

void main() {
  const first = PdfRect(10, 30, 20, 10);
  const second = PdfRect(40, 30, 50, 10);

  test(
    'new highlights join word gaps and retain partial endpoints and text',
    () {
      final range = textRange(
        1,
        [
          const PdfRect(0, 10, 5, 0),
          const PdfRect(5, 10, 10, 0),
          const PdfRect(10, 10, 12, 0),
          const PdfRect(20, 10, 25, 0),
          const PdfRect(25, 10, 30, 0),
        ],
        content: 'ab cd',
        start: 1,
        end: 4,
      );
      final region = HighlightRegion.fromTextRanges([
        range,
      ], includeText: true).single;
      expect(region.rects, [const PdfRect(5, 10, 25, 0)]);
      expect(region.text, 'b c');
      expect((range.start, range.end, range.text), (1, 4, 'b c'));
    },
  );

  test('new highlights preserve column gutters and explicit line breaks', () {
    final range = textRange(1, [
      const PdfRect(0, 30, 10, 20),
      const PdfRect(10, 30, 12, 20),
      const PdfRect(100, 30, 110, 20),
      PdfRect.empty,
      const PdfRect(0, 10, 10, 0),
      const PdfRect(10, 10, 12, 0),
      const PdfRect(15, 10, 25, 0),
    ], content: 'a b\nc d');
    final region = HighlightRegion.fromTextRanges([
      range,
    ], includeText: true).single;
    expect(region.rects, [
      const PdfRect(0, 30, 12, 20),
      const PdfRect(100, 30, 110, 20),
      const PdfRect(0, 10, 25, 0),
    ]);
    expect(region.text, 'a b\nc d');
  });

  test(
    'empty pages and separator fragments do not reject valid highlights',
    () {
      final regions = HighlightRegion.fromTextRanges([
        textRange(1, [first, PdfRect.empty, const PdfRect(20, 10, 25, 10)]),
        textRange(2, []),
        textRange(3, [PdfRect.empty]),
        textRange(4, [second]),
      ], includeText: true);
      expect(regions.map((r) => r.pageNumber), [1, 4]);
      expect(regions[0].rects, [first]);
      expect(regions[1].rects, [second]);
      expect(regions[0].text, 'xxx');
    },
  );

  test('selections without usable geometry are a no-op', () {
    final regions = HighlightRegion.fromTextRanges([
      textRange(1, []),
      textRange(2, [PdfRect.empty, const PdfRect(10, 20, 10, 0)]),
      textRange(3, [const PdfRect(-double.infinity, 20, 30, 0)]),
      textRange(4, [const PdfRect(0, double.infinity, 30, 0)]),
    ], includeText: true);
    expect(regions, isEmpty);
  });

  test('highlight geometry does not bypass text-copy restrictions', () {
    final regions = HighlightRegion.fromTextRanges([
      textRange(1, [first]),
    ], includeText: false);
    expect(regions.single.rects, [first]);
    expect(regions.single.text, isEmpty);
  });
}
