import 'dart:convert';
import 'dart:typed_data';

/// Imported highlights with duplicate/missing names, custom appearance resources,
/// popup/reply relationships, unrelated link, and opaque metadata. Hand-authored
/// so preservation assertions do not merely test our own annotation writer.
Uint8List annotationPdf({
  bool lockedSecondPopup = false,
  bool crossPageReply = false,
  bool relationships = true,
  String author = 'Imported author',
  bool unsupportedAppearance = false,
  bool overlapping = false,
  int payloadBytes = 0,
}) {
  final ap =
      'q /Custom gs /Ink cs 0.2 0.8 0.3 sc 20 100 110 20 re f Q'
      '${unsupportedAppearance ? ' 1 0 0 rg 30 105 20 10 re f' : ''}';
  final payload = 'x' * payloadBytes;
  final objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 200] /Resources << >> /PrivatePayload 14 0 R /Annots [5 0 R ${relationships ? '6 0 R 7 0 R' : ''} 8 0 R 9 0 R] >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 200] /Resources << >> /Annots [10 0 R ${relationships ? '11 0 R' : ''}] >>',
    '<< /Type /Annot /Subtype /Highlight /Rect [20 100 130 120] /QuadPoints [20 120 130 120 20 100 130 100] /F 4 /C [1 1 0] /CA 0.4 /Contents (custom) /T ($author) /NM (duplicate) ${relationships ? '/Popup 6 0 R' : ''} /AP << /N 12 0 R >> /PrivateData << /Nested [(untouched) 13 0 R] >> >>',
    '<< /Type /Annot /Subtype /Popup /Rect [200 50 300 140] /Parent 5 0 R /F 4 >>',
    '<< /Type /Annot /Subtype /Text /Rect [140 100 160 120] /IRT 5 0 R /Contents (reply) /F 4 >>',
    '<< /Type /Annot /Subtype /Highlight /Rect [20 50 130 70] /QuadPoints [20 70 130 70 20 50 130 50] /F 4 /C [1 1 0] /CA 0.4 /NM (duplicate) /T ($author) /Contents (standard) >>',
    '<< /Type /Annot /Subtype /Link /Rect ${overlapping ? '[20 100 130 120] /C [1 0 0] /Border [0 0 8]' : '[200 10 300 30]'} /A << /S /URI /URI (https://example.com) >> >>',
    '<< /Type /Annot /Subtype /Highlight /Rect [20 50 130 70] /QuadPoints [20 70 130 70 20 50 130 50] /F 4 /C [1 1 0] /CA 0.4 /T ($author) /Contents (second page) ${crossPageReply ? '/IRT 5 0 R' : ''} ${relationships ? '/Popup 11 0 R' : ''} >>',
    '<< /Type /Annot /Subtype /Popup /Rect [200 50 300 140] /Parent 10 0 R /F ${lockedSecondPopup ? 128 : 4} >>',
    '<< /Type /XObject /Subtype /Form /BBox [20 100 130 120] /Matrix [1 0 0 1 0 0] /Resources << /ExtGState << /Custom << /Type /ExtGState /ca 0.7 /BM /Multiply >> >> /ColorSpace << /Ink /DeviceRGB >> >> /Length ${ap.length} >>\nstream\n$ap\nendstream',
    '<< /Keep (opaque metadata) >>',
    '<< /Length ${payload.length} >>\nstream\n$payload\nendstream',
  ];
  final pdf = StringBuffer('%PDF-1.7\n');
  final offsets = List<int>.filled(objects.length + 1, 0);
  // Put annotation dictionaries beyond the large stream so reading them needs
  // a deferred file-access callback, independently of page-tree loading.
  final order = payloadBytes > 0
      ? [0, 1, 2, 3, 13, for (var i = 4; i < 13; i++) i]
      : [for (var i = 0; i < objects.length; i++) i];
  for (final i in order) {
    offsets[i + 1] = pdf.length;
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
