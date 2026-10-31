import 'dart:convert';
import 'dart:typed_data';

/// Actual cross-page GoTo links to cropped pages at every quarter rotation.
/// A red marker at (400, 500)-(460, 540) makes crop correctness measurable.
Uint8List hoverPdfFixture({
  String firstLocation = '400 540 null',
  Map<int, String?> annotationRects = const {},
}) {
  final objects = <String>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [4 0 R 6 0 R 8 0 R 10 0 R 12 0 R] /Count 5 >>',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
  ];
  const labels = [
    'Citation',
    'Figure rotated 90',
    'Figure rotated 180',
    'Figure rotated 270',
    'Whole page',
    'Figure rectangle',
    'External',
  ];
  final source = StringBuffer();
  for (var i = 0; i < labels.length; i++) {
    source.write('BT /F1 16 Tf 80 ${650 - i * 50} Td (${labels[i]}) Tj ET\n');
  }
  objects.addAll([
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 600 800] '
        '/Resources << /Font << /F1 3 0 R >> >> /Contents 5 0 R '
        '/Annots [14 0 R 15 0 R 16 0 R 17 0 R 18 0 R 19 0 R 20 0 R] >>',
    '<< /Length ${source.length} >>\nstream\n$source\nendstream',
  ]);
  for (var i = 0; i < 4; i++) {
    final stream =
        '1 0 0 rg 400 500 60 40 re f 0 0 0 rg '
        'BT /F1 16 Tf 350 460 Td (Linked target ${i + 1}) Tj ET';
    objects.addAll([
      '<< /Type /Page /Parent 2 0 R /MediaBox [10 20 610 820] '
          '/CropBox [30 40 590 800] /Rotate ${i * 90} '
          '/Resources << /Font << /F1 3 0 R >> >> /Contents ${7 + i * 2} 0 R >>',
      '<< /Length ${stream.length} >>\nstream\n$stream\nendstream',
    ]);
  }
  for (var i = 0; i < labels.length; i++) {
    final action = switch (i) {
      0 => '/Dest [6 0 R /XYZ $firstLocation]',
      < 4 => '/Dest [${6 + i * 2} 0 R /XYZ 400 540 null]',
      4 => '/Dest [6 0 R /Fit]',
      5 => '/Dest [8 0 R /FitR 400 500 460 540]',
      _ => '/A << /S /URI /URI (https://example.com/reference) >>',
    };
    final rect = annotationRects.containsKey(i)
        ? annotationRects[i]
        : '75 ${645 - i * 50} 350 ${670 - i * 50}';
    objects.add(
      '<< /Type /Annot /Subtype /Link '
      '${rect == null ? '' : '/Rect [$rect] '}'
      '/Border [0 0 0] $action >>',
    );
  }
  final pdf = StringBuffer('%PDF-1.7\n');
  final offsets = <int>[0];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(pdf.length);
    pdf.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
  }
  final xref = pdf.length;
  pdf.write('xref\n0 ${offsets.length}\n0000000000 65535 f \n');
  for (final offset in offsets.skip(1)) {
    pdf.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  pdf.write(
    'trailer\n<< /Size ${offsets.length} /Root 1 0 R >>\n'
    'startxref\n$xref\n%%EOF',
  );
  return Uint8List.fromList(ascii.encode(pdf.toString()));
}
