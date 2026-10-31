import 'package:pdfrx/pdfrx.dart';

import 'editable_pdf_document.dart';

/// The caller owns the document for this entire future (normally via the session
/// lock and lease). Pin the backing generation too when using the viewer proxy.
/// Only capture the address while the worker is suspended; resume it BEFORE
/// dispatching the synchronous operation. An ordinary compute/Isolate.run uses
/// the wrong isolate for PDFium's file-access and font callbacks.
Future<R> pdfiumDocumentTask<M, R>(
  PdfDocument document,
  R Function(int handle, M message) action,
  M message,
) async {
  if (document is EditablePdfDocument) {
    return document.withBackingDocument(
      (native) => pdfiumDocumentTask(native, action, message),
    );
  }
  final handle = await document.useNativeDocumentHandle((address) => address);
  final result = await PdfrxEntryFunctions.instance.compute(_dispatch<M, R>, (
    handle: handle,
    action: action,
    message: message,
  ));
  if (result.error case final error?) {
    switch (result.kind) {
      case 'unsupported':
        throw UnsupportedError(error);
      case 'argument':
        throw ArgumentError(error);
      default:
        throw StateError(error);
    }
  }
  return result.value as R;
}

class _Result<T> {
  const _Result(this.value, this.error, this.kind);
  final T? value;
  final String? error, kind;
}

_Result<R> _dispatch<M, R>(
  ({int handle, R Function(int, M) action, M message}) request,
) {
  try {
    return _Result(request.action(request.handle, request.message), null, null);
  } catch (error) {
    return _Result(
      null,
      error.toString(),
      error is UnsupportedError
          ? 'unsupported'
          : error is ArgumentError
          ? 'argument'
          : 'state',
    );
  }
}
