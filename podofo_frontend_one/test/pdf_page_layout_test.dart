import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:podofo_one/src/widgets/components/pdf_page_layout.dart';

class _Page extends Fake implements PdfPage {
  _Page(this.width, this.height);
  @override
  final double width;
  @override
  final double height;
}

void main() {
  const params = PdfViewerParams(margin: 10);

  test('pairs mixed-size pages without overlap or scaling', () {
    final layout = layoutTwoPages([
      _Page(300, 400),
      _Page(400, 300),
      _Page(200, 500),
      _Page(300, 400),
    ], params);
    expect(layout.documentSize, const Size(730, 930));
    expect(layout.pageLayouts, [
      const Rect.fromLTWH(10, 10, 300, 400),
      const Rect.fromLTWH(320, 60, 400, 300),
      const Rect.fromLTWH(110, 420, 200, 500),
      const Rect.fromLTWH(320, 470, 300, 400),
    ]);
    expect(
      pageViewBounds(layout, 2, twoPages: true),
      const Rect.fromLTWH(10, 10, 710, 400),
    );
    expect(
      pageViewBounds(layout, 4, twoPages: true),
      const Rect.fromLTWH(110, 420, 510, 500),
    );
    expect(pageViewBounds(layout, 2, twoPages: false), layout.pageLayouts[1]);
  });

  test('centers an unpaired last page and includes it in document bounds', () {
    final layout = layoutTwoPages([
      _Page(300, 400),
      _Page(300, 400),
      _Page(300, 400),
    ], params);
    expect(layout.pageLayouts.last, const Rect.fromLTWH(165, 420, 300, 400));
    expect(layout.documentSize, const Size(630, 830));
    expect(pageViewBounds(layout, 3, twoPages: true), layout.pageLayouts.last);
  });

  test('handles single-page and empty documents', () {
    final layout = layoutTwoPages([_Page(300, 400)], params);
    expect(layout.pageLayouts.single, const Rect.fromLTWH(10, 10, 300, 400));
    expect(layout.documentSize, const Size(320, 420));
    expect(layoutTwoPages([], params).pageLayouts, isEmpty);
  });
}
