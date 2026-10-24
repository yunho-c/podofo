import 'package:pdfrx/pdfrx.dart';

import '../services/pdf_session.dart';
import 'source_map.dart';

class ExtractedPaperPage {
  const ExtractedPaperPage(this.text, this.width, this.height);
  final PdfTextSnapshot text;
  final double width, height;
}

/// Holds no PDF objects in returned values. Callers bound their snapshot caches.
class PdfTextRepository {
  PdfTextRepository(this.session);
  final PdfSession session;

  Future<ExtractedPaperPage> extract(int number) =>
      session.readLocked((pdf) async {
        if (pdf.permissions?.allowsCopying == false) {
          throw StateError('This PDF does not allow text extraction.');
        }
        final page = pdf.pages[number - 1];
        final text = PdfTextSnapshot.fromText(
          await NarrationPdfPage(page).loadStructuredText(),
        );
        return ExtractedPaperPage(
          text,
          page.rotation.index.isOdd ? page.height : page.width,
          page.rotation.index.isOdd ? page.width : page.height,
        );
      });
}
