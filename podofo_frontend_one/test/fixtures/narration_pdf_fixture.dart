import 'dart:convert';
import 'dart:typed_data';

/// Tiny real PDFs with deterministic text geometry and optional Unicode mapping.
Uint8List narrationPdfFixture(List<String> streams, {String? unicodeMap}) {
  final font = 3 + 2 * streams.length;
  final objects = <String>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [${[for (var i = 0; i < streams.length; i++) '${3 + 2 * i} 0 R'].join(' ')}] /Count ${streams.length} >>',
    for (var i = 0; i < streams.length; i++) ...[
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 600 800] /Resources << /Font << /F1 $font 0 R >> >> /Contents ${4 + 2 * i} 0 R >>',
      '<< /Length ${streams[i].length} >>\nstream\n${streams[i]}endstream',
    ],
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica ${unicodeMap == null ? '' : '/ToUnicode ${font + 1} 0 R'} >>',
    if (unicodeMap != null)
      '<< /Length ${unicodeMap.length} >>\nstream\n${unicodeMap}endstream',
  ];
  final output = StringBuffer('%PDF-1.7\n'), offsets = <int>[];
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

const narrationUnicodeMap = '''/CIDInit /ProcSet findresource begin
12 dict begin begincmap
/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def
/CMapName /Adobe-Identity-UCS def /CMapType 2 def
1 begincodespacerange <00> <FF> endcodespacerange
3 beginbfchar <41> <D83DDE80> <42> <FB01> <43> <00E9> endbfchar
endcmap CMapName currentdict /CMap defineresource pop end end
''';
