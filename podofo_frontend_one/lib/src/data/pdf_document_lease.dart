import 'dart:async';

import 'package:pdfrx/pdfrx.dart';

/// One shared native document, kept alive by its session, viewer and active jobs.
///
/// Closing a tab releases the session's reference. pdfrx disposes the native
/// document only after the viewer detaches and outstanding useDocument jobs end.
class PdfDocumentLease {
  PdfDocumentLease(PdfDocument document)
    : reference = PdfDocumentRefDirect(
        document,
        // A checkpoint and its stable viewer proxy can have the same source
        // name. Each independently owned native lifetime needs its own cache key.
        key: PdfDocumentRefKey(document.sourceName, [Object()]),
      ) {
    _listenable = reference.resolveListenable();
    _releaseOwner = _listenable.addListener(() {});
    _listenable.setDocument(document);
  }

  final PdfDocumentRefDirect reference;
  late final PdfDocumentListenable _listenable;
  late final void Function() _releaseOwner;
  bool _closed = false;

  bool get isClosed => _closed;
  PdfDocument get document {
    if (_closed) throw StateError('Document is closed');
    return _listenable.document!;
  }

  Future<T> use<T>(FutureOr<T> Function(PdfDocument document) task) async {
    if (_closed) throw StateError('Document is closed');
    // The owner's reference guarantees that the document is already loaded.
    final result = await _listenable.useDocument<T>(task, ensureLoaded: false);
    return result as T;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _releaseOwner();
  }
}
