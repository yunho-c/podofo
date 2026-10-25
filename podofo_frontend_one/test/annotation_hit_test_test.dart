import 'package:flutter_test/flutter_test.dart';
import 'package:podofo_one/src/editing/annotation_edit.dart';
import 'package:podofo_one/src/editing/annotation_hit_test.dart';

AnnotationRecord mark(
  String id,
  int index,
  List<List<double>> quads, {
  int flags = 4,
  int page = 1,
  String author = 'PoDoFo',
}) => AnnotationRecord(
  id: id,
  pageNumber: page,
  index: index,
  contents: '',
  author: author,
  pdfName: id,
  flags: flags,
  argb: 0x66ffff00,
  hasAppearance: false,
  quads: quads,
  bounds: [0, 100, 100, 0],
);

void main() {
  const top = <double>[10.0, 90, 40, 90, 10, 80, 40, 80];
  const bottom = <double>[10.0, 60, 40, 60, 10, 50, 40, 50];
  test('individual quads exclude line and column gaps and other pages', () {
    final a = mark('a', 0, [top, bottom]);
    expect(textMarkupAt([a], 1, 20, 85), same(a));
    expect(textMarkupAt([a], 1, 20, 55), same(a));
    expect(textMarkupAt([a], 1, 10, 80), same(a));
    expect(textMarkupAt([a], 1, 20, 70), isNull);
    expect(textMarkupAt([a], 1, 60, 85), isNull);
    expect(textMarkupAt([a], 2, 20, 85), isNull);
  });
  test('skewed quads exclude their bounding-box corners', () {
    final a = mark('a', 0, [
      [20, 90, 50, 90, 10, 80, 40, 80],
    ]);
    expect(textMarkupAt([a], 1, 30, 85), same(a));
    expect(textMarkupAt([a], 1, 11, 89), isNull);
    expect(
      textMarkupAt(
        [
          mark('bad', 0, [
            [0, 0, 0, 0, 0, 0, 0, 0],
          ]),
        ],
        1,
        0,
        0,
      ),
      isNull,
    );
  });
  test('topmost visible annotation wins even if read-only', () {
    final a = mark('a', 0, [top]);
    final b = mark('b', 3, [top], author: 'Someone else');
    expect(textMarkupAt([b, a], 1, 20, 85), same(b));
    for (final flags in [2, 32]) {
      expect(
        textMarkupAt(
          [
            a,
            mark('hidden', 5, [top], flags: flags),
          ],
          1,
          20,
          85,
        ),
        same(a),
      );
    }
  });
}
