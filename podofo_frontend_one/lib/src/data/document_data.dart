import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';

import '../services/pdf_session.dart';

class Document {
  Document({
    required this.session,
    this.lastOpenedPage,
    this.twoPageView = false,
  });
  final PdfSession session;
  final int? lastOpenedPage;

  /// View preference for this open tab; it does not modify the PDF.
  final bool twoPageView;
  String get filePath => session.path;
  PdfDocument get pdfDocument => session.lease.document;
  String get title => p.basename(filePath);
  bool get dirty => session.dirty;
  Document copyWith({int? lastOpenedPage, bool? twoPageView}) => Document(
    session: session,
    lastOpenedPage: lastOpenedPage ?? this.lastOpenedPage,
    twoPageView: twoPageView ?? this.twoPageView,
  );
}
