import 'package:pdfrx_engine/pdfrx_engine.dart';

/// Backport of staging's navigation predicate without replacing the PDF engine.
extension PdfLinkNavigation on PdfLink {
  /// Whether this entry has a URL or an in-document destination.
  /// Annotation-only entries have neither and are not navigable links.
  bool get isNavigable => url != null || dest != null;
}
