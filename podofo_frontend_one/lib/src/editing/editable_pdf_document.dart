import 'dart:async';
import 'dart:typed_data';

import 'package:pdfrx/pdfrx.dart';

import '../data/pdf_document_lease.dart';

/// A stable viewer identity that can replace its backing after failure recovery.
/// Ordinary annotation edits mutate the existing backing on its PDFium worker.
/// Page and native tasks pin that generation until their asynchronous work ends;
/// recovery preserves page geometry and emits events without resetting the view.
class EditablePdfDocument extends PdfDocument {
  EditablePdfDocument(PdfDocument document)
    : super(sourceName: document.sourceName) {
    _native = PdfDocumentLease(document);
    _subscribe();
    _updatePages();
  }
  late PdfDocumentLease _native;
  late List<PdfPage> _pages;
  StreamSubscription<PdfDocumentEvent>? _subscription;
  final _events = StreamController<PdfDocumentEvent>.broadcast();
  bool _disposed = false;

  Future<T> _use<T>(FutureOr<T> Function(PdfDocument) task) =>
      _native.use(task);

  /// Pins one native generation across a worker task, including handle capture.
  Future<T> withBackingDocument<T>(FutureOr<T> Function(PdfDocument) task) =>
      _use(task);

  void _updatePages() => _pages = List.unmodifiable([
    for (var i = 0; i < _native.document.pages.length; i++)
      _EditablePage(this, i + 1),
  ]);
  void _subscribe() {
    final generation = _native;
    _subscription = generation.document.events.listen((event) {
      if (_disposed || !identical(generation, _native)) return;
      if (event is PdfDocumentPageStatusChangedEvent) {
        _updatePages();
        _notify(event.changes.keys);
      } else if (event is PdfDocumentLoadCompleteEvent) {
        _events.add(PdfDocumentLoadCompleteEvent(this));
      } else if (event is PdfDocumentMissingFontsEvent) {
        _events.add(PdfDocumentMissingFontsEvent(this, event.missingFonts));
      }
    });
  }

  void _notify(Iterable<int> pages) => _events.add(
    PdfDocumentPageStatusChangedEvent(
      this,
      changes: {
        for (final number in pages)
          number: PdfPageStatusChange.modified(page: _pages[number - 1]),
      },
    ),
  );

  /// Takes ownership only after validation. The caller must publish matching
  /// model/history synchronously in the same turn, before async event delivery.
  void replace(PdfDocument candidate, Set<int> affectedPages) {
    if (_disposed) throw StateError('Document is closed.');
    if (candidate.pages.length != _pages.length ||
        affectedPages.any((p) => p < 1 || p > _pages.length)) {
      throw StateError('Annotation edit changed page structure.');
    }
    for (var i = 0; i < _pages.length; i++) {
      final a = _pages[i], b = candidate.pages[i];
      if (a.width != b.width ||
          a.height != b.height ||
          a.rotation != b.rotation) {
        throw StateError('Annotation edit changed page geometry.');
      }
    }
    final previous = _native;
    _subscription?.cancel();
    _native = PdfDocumentLease(candidate);
    _subscribe();
    _updatePages();
    _notify(affectedPages);
    previous.close();
  }

  @override
  PdfPermissions? get permissions => _native.document.permissions;
  @override
  bool get isEncrypted => _native.document.isEncrypted;
  @override
  Stream<PdfDocumentEvent> get events => _events.stream;
  @override
  List<PdfPage> get pages => _pages;
  @override
  set pages(List<PdfPage> value) {
    throw UnsupportedError(
      'Page structure edits require a document transaction.',
    );
  }

  @override
  Future<void> loadPagesProgressively<T>({
    PdfPageLoadingCallback<T>? onPageLoadProgress,
    T? data,
    Duration loadUnitDuration = const Duration(milliseconds: 250),
    int? startPageNumber,
  }) => _use(
    (pdf) => pdf.loadPagesProgressively(
      onPageLoadProgress: onPageLoadProgress,
      data: data,
      loadUnitDuration: loadUnitDuration,
      startPageNumber: startPageNumber,
    ),
  );
  @override
  Future<List<PdfOutlineNode>> loadOutline() =>
      _use((pdf) => pdf.loadOutline());
  @override
  bool isIdenticalDocumentHandle(Object? other) =>
      identical(this, other) ||
      _native.document.isIdenticalDocumentHandle(other);
  @override
  Future<bool> assemble() => _use((pdf) => pdf.assemble());
  @override
  Future<Uint8List> encodePdf({
    bool incremental = false,
    bool removeSecurity = false,
  }) => _use(
    (pdf) =>
        pdf.encodePdf(incremental: incremental, removeSecurity: removeSecurity),
  );
  @override
  Future<T> useNativeDocumentHandle<T>(FutureOr<T> Function(int) task) =>
      _use((pdf) => pdf.useNativeDocumentHandle(task));
  @override
  Future<void> reloadPages({List<int>? pageNumbersToReload}) =>
      _use((pdf) => pdf.reloadPages(pageNumbersToReload: pageNumbersToReload));
  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final cancelled = _subscription?.cancel();
    // Initiate native release synchronously, before a caller can enqueue
    // PDFium shutdown. Active operations still pin the backing lease.
    _native.close();
    await cancelled;
    await _events.close();
  }
}

class _EditablePage implements PdfPage {
  _EditablePage(this.document, this.pageNumber);
  @override
  final EditablePdfDocument document;
  @override
  final int pageNumber;
  PdfPage get basePage => document._native.document.pages[pageNumber - 1];
  @override
  double get width => basePage.width;
  @override
  double get height => basePage.height;
  @override
  PdfPageRotation get rotation => basePage.rotation;
  @override
  bool get isLoaded => basePage.isLoaded;
  Future<T> _use<T>(Future<T> Function(PdfPage) task) =>
      document._use((pdf) => task(pdf.pages[pageNumber - 1]));
  @override
  PdfPageRenderCancellationToken createCancellationToken() =>
      basePage.createCancellationToken();
  @override
  Future<PdfPageRawText?> loadText() => _use((page) => page.loadText());
  @override
  Future<List<PdfLink>> loadLinks({
    bool compact = false,
    bool enableAutoLinkDetection = true,
  }) => _use(
    (page) => page.loadLinks(
      compact: compact,
      enableAutoLinkDetection: enableAutoLinkDetection,
    ),
  );
  @override
  Future<PdfImage?> render({
    int x = 0,
    int y = 0,
    int? width,
    int? height,
    double? fullWidth,
    double? fullHeight,
    int? backgroundColor,
    PdfPageRotation? rotationOverride,
    PdfAnnotationRenderingMode annotationRenderingMode =
        PdfAnnotationRenderingMode.annotationAndForms,
    int flags = PdfPageRenderFlags.none,
    PdfPageRenderCancellationToken? cancellationToken,
  }) => _use(
    (page) => page.render(
      x: x,
      y: y,
      width: width,
      height: height,
      fullWidth: fullWidth,
      fullHeight: fullHeight,
      backgroundColor: backgroundColor,
      rotationOverride: rotationOverride,
      annotationRenderingMode: annotationRenderingMode,
      flags: flags,
      cancellationToken: cancellationToken,
    ),
  );
}
