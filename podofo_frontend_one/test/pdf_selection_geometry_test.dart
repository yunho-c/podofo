import 'package:pdfrx/pdfrx.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PdfPageTextRange.enumerateSelectionRects', () {
    final words = _text([
      ('ab', const PdfRect(0, 10, 10, 0)),
      (' ', const PdfRect(10, 10, 12.5, 0)),
      ('cd', const PdfRect(20, 10, 30, 0)),
      (' ', const PdfRect(30, 10, 32.5, 0)),
      ('ef', const PdfRect(40, 10, 50, 0)),
    ]);

    test(
      'fills word gaps without changing text, indices, or character geometry',
      () {
        final range = PdfPageTextRange(pageText: words, start: 1, end: 7);
        final originalRects = List<PdfRect>.of(words.charRects);
        final originalFragments = range
            .enumerateFragmentBoundingRects()
            .toList();

        expect(range.enumerateSelectionRects(), [const PdfRect(5, 10, 45, 0)]);
        expect(range.text, 'b cd e');
        expect((range.start, range.end), (1, 7));
        expect(words.fullText, 'ab cd ef');
        expect(words.charRects, originalRects);
        expect(range.enumerateFragmentBoundingRects(), originalFragments);
      },
    );

    test('does not extend a partial word or a trailing selected space', () {
      expect(_rects(words, start: 1, end: 2), [const PdfRect(5, 10, 10, 0)]);
      expect(_rects(words, end: 3), [const PdfRect(0, 10, 12.5, 0)]);
      expect(_rects(words, start: 2, end: 3), [const PdfRect(10, 10, 12.5, 0)]);
      expect(_rects(words, start: 2, end: 4), [const PdfRect(10, 10, 25, 0)]);
    });

    test('joins ordinary spaces and mixed font sizes on the same line', () {
      final text = _text([
        ('small', const PdfRect(0, 10, 25, 0)),
        (' ', const PdfRect(25, 10, 28, 0)),
        ('BIG', const PdfRect(28, 16, 58, 0)),
        ('word', const PdfRect(60, 12, 80, -1)),
      ]);
      expect(_rects(text), [const PdfRect(0, 16, 80, -1)]);
    });

    test('keeps large column gutters open', () {
      final text = _text([
        ('ab', const PdfRect(0, 10, 10, 0)),
        (' ', const PdfRect(10, 10, 12.5, 0)),
        ('cd', const PdfRect(200, 10, 210, 0)),
      ]);
      expect(_rects(text), [
        const PdfRect(0, 10, 12.5, 0),
        const PdfRect(200, 10, 210, 0),
      ]);
    });

    test('measures the full column gap even after a wide capped space', () {
      final text = _text([
        ('ab', const PdfRect(0, 10, 10, 0)),
        (' ', const PdfRect(10, 10, 25, 0)),
        ('cd', const PdfRect(35, 10, 45, 0)),
      ]);
      expect(_rects(text), [
        const PdfRect(0, 10, 25, 0),
        const PdfRect(35, 10, 45, 0),
      ]);
    });

    test('does not merge geometrically close fragments across explicit line breaks', () {
      for (final separator in ['\n', '\r\n', '\t', '\u2028', '\u2029']) {
        final text = _text([
          ('ab', const PdfRect(0, 10, 10, 0)),
          (separator, const PdfRect(10, 10, 10, 0)),
          ('cd', const PdfRect(12, 10, 22, 0)),
        ]);
        expect(_rects(text), [
          const PdfRect(0, 10, 10, 0),
          const PdfRect(12, 10, 22, 0),
        ]);
      }
    });

    test('separates adjacent lines and prevents cumulative line drift', () {
      final text = _text([
        ('ab', const PdfRect(0, 30, 10, 20)),
        ('cd', const PdfRect(12, 26, 22, 16)),
        ('ef', const PdfRect(24, 22, 34, 12)),
        ('gh', const PdfRect(36, 10, 46, 0)),
      ]);
      expect(_rects(text), [
        const PdfRect(0, 30, 22, 16),
        const PdfRect(24, 22, 34, 12),
        const PdfRect(36, 10, 46, 0),
      ]);
    });

    test('does not merge a run that goes backwards or changes direction', () {
      final backwards = _text([
        ('ab', const PdfRect(20, 10, 30, 0)),
        ('cd', const PdfRect(0, 10, 10, 0)),
      ]);
      expect(_rects(backwards), [
        const PdfRect(20, 10, 30, 0),
        const PdfRect(0, 10, 10, 0),
      ]);
      final mixed = _text(
        [
          ('ab', const PdfRect(0, 10, 10, 0)),
          ('cd', const PdfRect(12, 10, 22, 0)),
        ],
        directions: [PdfTextDirection.ltr, PdfTextDirection.rtl],
      );
      expect(_rects(mixed), [
        const PdfRect(0, 10, 10, 0),
        const PdfRect(12, 10, 22, 0),
      ]);
      final unknown = _text([
        ('ab', const PdfRect(0, 10, 10, 0)),
        ('cd', const PdfRect(12, 10, 22, 0)),
      ], direction: PdfTextDirection.unknown);
      expect(_rects(unknown), [
        const PdfRect(0, 10, 10, 0),
        const PdfRect(12, 10, 22, 0),
      ]);
    });

    test('requires neighboring fragments to share a line as well as the first fragment', () {
      final text = _text([
        ('ab', const PdfRect(0, 20, 10, 10)),
        ('cd', const PdfRect(12, 25, 22, 15)),
        ('ef', const PdfRect(24, 15, 34, 5)),
      ]);
      expect(_rects(text), [
        const PdfRect(0, 25, 22, 10),
        const PdfRect(24, 15, 34, 5),
      ]);
    });

    test('requires contiguous text indices even when rectangles align', () {
      final text = _text([
        ('ab', const PdfRect(0, 10, 10, 0)),
        (' ', const PdfRect(10, 10, 12, 0)),
        ('cd', const PdfRect(12, 10, 22, 0)),
      ]);
      text.fragments.removeAt(1);
      expect(_rects(text), [
        const PdfRect(0, 10, 10, 0),
        const PdfRect(12, 10, 22, 0),
      ]);
    });

    test('joins overlapping fragments once and skips empty space geometry', () {
      final text = _text([
        ('ab', const PdfRect(0, 10, 10, 0)),
        ('cd', const PdfRect(9, 10, 19, 0)),
        (' ', const PdfRect(0, 0, 0, 0)),
        ('ef', const PdfRect(23, 10, 33, 0)),
      ]);
      expect(_rects(text), [const PdfRect(0, 10, 33, 0)]);
    });

    test('joins RTL word gaps while retaining partial endpoints', () {
      final text = _text([
        ('ab', const PdfRect(40, 10, 50, 0)),
        (' ', const PdfRect(37.5, 10, 40, 0)),
        ('cd', const PdfRect(20, 10, 30, 0)),
      ], direction: PdfTextDirection.rtl);
      expect(_rects(text, start: 1, end: 4), [const PdfRect(25, 10, 45, 0)]);
      expect(_rects(text, end: 3), [const PdfRect(37.5, 10, 50, 0)]);
      expect(PdfPageTextRange(pageText: text, start: 1, end: 4).text, 'b c');
    });

    test('joins vertical word gaps but separates adjacent columns', () {
      final text = _text([
        ('ab', const PdfRect(20, 100, 30, 80)),
        (' ', const PdfRect(20, 80, 30, 77.5)),
        ('cd', const PdfRect(20, 70, 30, 50)),
        ('ef', const PdfRect(5, 100, 15, 80)),
      ], direction: PdfTextDirection.vrtl);
      expect(_rects(text, start: 1, end: 4), [const PdfRect(20, 90, 30, 60)]);
      expect(_rects(text), [
        const PdfRect(20, 100, 30, 50),
        const PdfRect(5, 100, 15, 80),
      ]);
    });

    test('produces no rectangles for an empty selection or page', () {
      expect(_rects(words, start: 1, end: 1), isEmpty);
      expect(_rects(words, start: words.fullText.length), isEmpty);
      expect(_rects(_text([])), isEmpty);
    });
  });
}

List<PdfRect> _rects(PdfPageText text, {int start = 0, int? end}) =>
    PdfPageTextRange(
      pageText: text,
      start: start,
      end: end ?? text.fullText.length,
    ).enumerateSelectionRects().toList();

PdfPageText _text(
  List<(String, PdfRect)> runs, {
  PdfTextDirection direction = PdfTextDirection.ltr,
  List<PdfTextDirection>? directions,
}) {
  final fragments = <PdfPageTextFragment>[];
  final rects = <PdfRect>[];
  final text = PdfPageText(
    pageNumber: 1,
    fullText: runs.map((run) => run.$1).join(),
    charRects: rects,
    fragments: fragments,
  );
  for (var i = 0; i < runs.length; i++) {
    final (value, bounds) = runs[i];
    final dir = directions?[i] ?? direction;
    final start = rects.length;
    for (var j = 0; j < value.length; j++) {
      rects.add(switch (dir) {
        PdfTextDirection.rtl => PdfRect(
          bounds.right - bounds.width * (j + 1) / value.length,
          bounds.top,
          bounds.right - bounds.width * j / value.length,
          bounds.bottom,
        ),
        PdfTextDirection.vrtl => PdfRect(
          bounds.left,
          bounds.top - bounds.height * j / value.length,
          bounds.right,
          bounds.top - bounds.height * (j + 1) / value.length,
        ),
        _ => PdfRect(
          bounds.left + bounds.width * j / value.length,
          bounds.top,
          bounds.left + bounds.width * (j + 1) / value.length,
          bounds.bottom,
        ),
      });
    }
    fragments.add(
      PdfPageTextFragment(
        pageText: text,
        index: start,
        length: value.length,
        bounds: bounds,
        charRects: rects.sublist(start),
        direction: dir,
      ),
    );
  }
  return text;
}
