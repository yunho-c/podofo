import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';

import '../services/pdf_session.dart';

class Document {
  Document({required this.session, this.lastOpenedPage});
  final PdfSession session;
  final int? lastOpenedPage;
  String get filePath => session.path;
  PdfDocument get pdfDocument => session.lease.document;
  String get title => p.basename(filePath);
  bool get dirty => session.dirty;
  Document copyWith({int? lastOpenedPage}) => Document(
    session: session,
    lastOpenedPage: lastOpenedPage ?? this.lastOpenedPage,
  );
}
