import 'dart:convert';
import 'dart:typed_data';

/// Three pages with real GoTo annotations, including a nested citation and a
/// same-page link. No network requests or user documents are needed.
Uint8List linkedPdfFixture() {
  final objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [4 0 R 7 0 R 10 0 R] /Count 3 >>',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
  ];
  for (var page = 0; page < 3; page++) {
    final index = 4 + page * 3;
    final next = page < 2 ? index + 3 : index;
    final label = [
      'Read citation on page 2',
      'Read citation on page 3',
      'Jump within this page',
    ][page];
    final stream =
        'BT /F1 18 Tf 100 620 Td (Page ${page + 1}) Tj '
        '0 -155 Td ($label) Tj ET';
    objects.addAll([
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 600 800] '
          '/Resources << /Font << /F1 3 0 R >> >> /Contents ${index + 1} 0 R '
          '/Annots [${index + 2} 0 R] >>',
      '<< /Length ${stream.length} >>\nstream\n$stream\nendstream',
      '<< /Type /Annot /Subtype /Link /Rect [95 450 350 485] '
          '/Border [0 0 0] /Dest [$next 0 R /XYZ 50 ${page < 2 ? 700 : 400} 1.5] >>',
    ]);
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
    'trailer\n<< /Size ${offsets.length} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF',
  );
  return Uint8List.fromList(ascii.encode(pdf.toString()));
}
