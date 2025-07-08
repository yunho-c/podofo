import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';

class Document {
  Document({
    required this.filePath,
    required this.pdfDocument,
    this.lastOpenedPage,
  }) : title = p.basename(filePath);
  final String filePath;
  final PdfDocument pdfDocument;
  final String title;
  final int? lastOpenedPage;

  Document copyWith({
    String? filePath,
    PdfDocument? pdfDocument,
    int? lastOpenedPage,
  }) {
    return Document(
      filePath: filePath ?? this.filePath,
      pdfDocument: pdfDocument ?? this.pdfDocument,
      lastOpenedPage: lastOpenedPage ?? this.lastOpenedPage,
    );
  }
}
