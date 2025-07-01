import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';

class Document {
  Document({
    required this.filePath,
    required this.pdfDocument,
  }) : title = p.basename(filePath);
  final String filePath;
  final PdfDocument pdfDocument;
  final String title;
}
