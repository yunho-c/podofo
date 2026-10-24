import 'dart:convert';
import 'dart:typed_data';

/// Hand-authored PDF: text on normal, cropped, and rotated pages; no downloads.
Uint8List pdfFixture({int pageCount = 3}) {
  assert(pageCount >= 1 && pageCount <= 3);
  const text = 'BT /F1 18 Tf 60 300 Td (Hello highlight) Tj ET\n';
  final kids = ['3 0 R', '5 0 R', '7 0 R'].take(pageCount).join(' ');
  final objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [$kids] /Count $pageCount >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [10 20 310 420] /CropBox [30 40 290 400] /Resources << /Font << /F1 9 0 R >> >> /Contents 4 0 R >>',
    '<< /Length ${text.length} >>\nstream\n${text}endstream',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] /Rotate 90 /Resources << /Font << /F1 9 0 R >> >> /Contents 6 0 R >>',
    '<< /Length ${text.length} >>\nstream\n${text}endstream',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] /Resources << /Font << /F1 9 0 R >> >> /Contents 8 0 R >>',
    '<< /Length ${text.length} >>\nstream\n${text}endstream',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
  ];
  final output = StringBuffer('%PDF-1.7\n');
  final offsets = <int>[];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(output.length);
    output.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
  }
  final xref = output.length;
  output.write('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
  for (final offset in offsets) {
    output.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  output.write(
    'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n',
  );
  return Uint8List.fromList(ascii.encode(output.toString()));
}
