import 'dart:convert';
import 'dart:typed_data';

// Separate text objects generate spaces with capped rectangles. The first gap
// is ordinary word spacing; the second represents a column gutter.
Uint8List spacedTextPdf({int rotation = 0, bool cropped = false}) {
  const stream =
      'BT /F1 20 Tf 40 140 Td (The) Tj 48 0 Td (vertical) Tj 180 0 Td (curve) Tj ET';
  final objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [4 0 R] /Count 1 >>',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Courier >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 200] '
        '${cropped ? '/CropBox [10 20 390 190] ' : ''}/Rotate $rotation '
        '/Resources << /Font << /F1 3 0 R >> >> /Contents 5 0 R >>',
    '<< /Length ${stream.length} >>\nstream\n$stream\nendstream',
  ];
  final pdf = StringBuffer('%PDF-1.4\n');
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
