import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:podofo_one/src/narration/source_map.dart';

void main() {
  test('ligatures, combining marks and surrogate pairs retain original source ranges', () {
    const text = 'A ﬁ 🚀 e\u0301 한글';
    final glyphs = [
      for (var i = 0; i < text.runes.length; i++)
        PdfRect(i * 10, 20, i * 10 + 8, 10),
    ];
    final page = PdfTextSnapshot(page: 1, text: text, boxes: glyphs);
    expect(page.boxes.length, text.length);
    expect(page.boxes[4], page.boxes[5]);
    final passage = NarrationPassage.fromSlices([
      PdfTextSlice(page, 0, text.length),
    ]);
    expect(passage.text, 'A fi 🚀 e\u0301 한글');
    expect(
      passage.anchorAt(3)!.offset,
      2,
    ); // Both f/i point at the PDF ligature.
    expect(passage.anchorAt(5)!.offset, 4);
    expect(
      passage.anchorAt(6)!.offset,
      4,
    ); // Both UTF-16 units use the rocket box.
    expect(passage.rectangles(1, 2, 4), [glyphs[2]]);
    expect(passage.rectangles(1, 5, 7), [glyphs[4]]);
    final resumed = passage.sliceFrom(5);
    expect(resumed.text, '🚀 e\u0301 한글');
    expect(resumed.anchorAt(0)!.offset, 4);
    expect(passage.offsetOf(resumed.anchorAt(0)!), 5);
  });

  test(
    'whitespace cleanup maps multiple page slices without painting page gaps',
    () {
      PdfTextSnapshot page(int number, String text) => PdfTextSnapshot(
        page: number,
        text: text,
        boxes: List.filled(text.length, const PdfRect(10, 20, 15, 10)),
      );
      final a = page(1, '  First\r\nline.  '), b = page(2, 'Second page.');
      final passage = NarrationPassage.fromSlices([
        PdfTextSlice(a, 0, a.text.length),
        PdfTextSlice(b, 0, b.text.length),
      ]);
      expect(passage.text, 'First line. Second page.');
      expect(passage.anchorAt(0)!.offset, 2);
      expect(passage.anchorAt(12)!.page, 2);
      expect(passage.rectangles(2, 0, 11), isEmpty);
      expect(passage.rectangles(1, 12, passage.text.length), isEmpty);
      expect(passage.offsetOf(SourceAnchor(1, 2, 'changed')), isNull);
    },
  );

  test(
    'invalid geometry lengths fail before producing misleading highlights',
    () {
      expect(
        () => PdfTextSnapshot(page: 1, text: 'abc', boxes: []),
        throwsStateError,
      );
    },
  );
}
