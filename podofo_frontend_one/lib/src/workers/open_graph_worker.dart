/// Link cards deliberately display destinations without fetching them.
/// Merely hovering a PDF must not contact its author or an arbitrary host.
String linkPreviewLabel(Uri uri) {
  if (!canOpenExternalLink(uri)) return 'Unsupported link: ${uri.scheme}';
  return uri.toString();
}

bool canOpenExternalLink(Uri uri) =>
    (uri.scheme == 'https' || uri.scheme == 'http') &&
    uri.host.isNotEmpty &&
    uri.userInfo.isEmpty;
