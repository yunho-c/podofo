import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';
import 'package:synchronized/synchronized.dart';

import '../data/pdf_document_lease.dart';
import '../editing/annotation_edit.dart';
import '../editing/annotation_hit_test.dart';
import '../editing/document_history.dart';
import '../editing/editable_pdf_document.dart';
import '../editing/pdf_annotation_adapter.dart';
import 'pdf_highlights.dart';
import 'document_file_access.dart';
import 'pdf_navigation_history.dart';

/// One live PDF, annotation-only history, and serialized editing/save/close.
class PdfSession {
  PdfSession._(
    this.path,
    this.lease,
    this._fingerprint,
    this._savedBytes,
    this._historyByteLimit,
    this._historyEntryLimit,
    this._adapter,
  ) : _baselineBytes = _savedBytes;
  String path;
  final PdfDocumentLease lease;
  final navigationHistory = PdfNavigationHistory();
  String _fingerprint;
  Uint8List _savedBytes;
  final Uint8List _baselineBytes;
  final Lock _lock = Lock();
  String? fileAccessWarning;
  int revision = 0;
  final PdfAnnotationAdapter _adapter;
  final int _historyByteLimit, _historyEntryLimit;
  DocumentHistory? _history;
  Map<String, AnnotationRecord>? _model;
  Future<void>? _annotationLoad;
  String? _editingFailure;
  bool get dirty => _history?.dirty ?? false;
  bool get canUndo => _editingFailure == null && (_history?.canUndo ?? false);
  bool get canRedo => _editingFailure == null && (_history?.canRedo ?? false);
  String? get undoLabel => _history?.undoLabel;
  String? get redoLabel => _history?.redoLabel;
  int get retainedHistoryBytes => _history?.retainedBytes ?? 0;
  String get cacheKey => '$_fingerprint-$revision';

  bool get annotationsReady => _model != null;

  /// Share the initial scan without making subsequent hit tests wait for edits
  /// or saves. An empty loaded model is distinct from one that is not ready.
  Future<void> prepareAnnotations() =>
      _annotationLoad ??= _lock.synchronized(() async {
        await _ensureHistory();
      });

  /// Read only committed Dart records. Native access still uses the session lock.
  AnnotationRecord? annotationAt(int pageNumber, double x, double y) {
    lease.document;
    if (_editingFailure case final failure?) throw StateError(failure);
    final model = _model;
    if (model == null) throw StateError('Annotations are not ready.');
    return textMarkupAt(
      model.values
          .where((a) => a.pageNumber == pageNumber)
          .map(_adapter.located),
      pageNumber,
      x,
      y,
    );
  }

  Future<DocumentHistory> _ensureHistory() async {
    lease.document;
    if (_editingFailure case final failure?) throw StateError(failure);
    if (_history == null) {
      _model = await lease.use(_adapter.initialize);
      _history = DocumentHistory(
        byteLimit: _historyByteLimit,
        entryLimit: _historyEntryLimit,
      );
    }
    return _history!;
  }

  Future<List<AnnotationRecord>> annotations() => _lock.synchronized(() async {
    await _ensureHistory();
    return List.unmodifiable(_model!.values.map(_adapter.located));
  });
  Future<void> waitForIdle() => _lock.synchronized(() {});
  Future<T> readLocked<T>(Future<T> Function(PdfDocument) read) =>
      _lock.synchronized(() => lease.use(read));

  static Future<PdfSession> open(
    String path, {
    bool selected = false,
    int historyByteLimit = 64 * 1024 * 1024,
    int historyEntryLimit = 100,
    PdfAnnotationAdapter? annotationAdapter,
  }) async {
    if (historyByteLimit < 1 || historyEntryLimit < 1) {
      throw ArgumentError('Invalid history limits.');
    }
    final access = await DocumentFileAccess.acquire(path, selected: selected);
    try {
      final contents = await access.read();
      path = contents.path;
      final bytes = contents.bytes;
      final pdf = await PdfDocument.openData(
        bytes,
        sourceName: path,
        useProgressiveLoading: false,
      );
      final session = PdfSession._(
        path,
        PdfDocumentLease(EditablePdfDocument(pdf)),
        sha256.convert(bytes).toString(),
        bytes,
        historyByteLimit,
        historyEntryLimit,
        annotationAdapter ?? PdfAnnotationAdapter(),
      );
      // Opening the reader does not wait for the annotation scan. Consumers of
      // prepareAnnotations still receive its error if a PDF cannot be scanned.
      unawaited(session.prepareAnnotations().catchError((Object _) {}));
      return session;
    } finally {
      await access.release();
    }
  }

  Future<void> highlight(List<HighlightRegion> regions, int argb) =>
      _addTextMarkup(regions, argb, AnnotationKind.highlight);

  Future<void> underline(List<HighlightRegion> regions) => _addTextMarkup(
    regions,
    AnnotationRecord.underlineColor,
    AnnotationKind.underline,
  );

  Future<void> _addTextMarkup(
    List<HighlightRegion> regions,
    int argb,
    AnnotationKind kind,
  ) {
    if (argb < 0 || argb > 0xffffffff) throw ArgumentError('Invalid color.');
    final frozen = List<HighlightRegion>.unmodifiable([
      for (final r in regions)
        HighlightRegion(r.pageNumber, List.unmodifiable(r.rects), text: r.text),
    ]);
    return _lock.synchronized(() async {
      if (frozen.isEmpty) return;
      await _ensureHistory();
      await _commit(_adapter.create(lease.document, frozen, argb, kind: kind));
    });
  }

  Future<void> _commit(AnnotationEdit edit) =>
      _apply(edit, _history!.commit(edit));

  Future<void> _recover() async {
    PdfDocument? candidate;
    try {
      candidate = await PdfDocument.openData(
        _baselineBytes,
        sourceName: 'annotation-recovery',
        useProgressiveLoading: false,
      );
      await _adapter.recover(candidate, _model!);
      (lease.document as EditablePdfDocument).replace(candidate, {
        for (var p = 1; p <= candidate.pages.length; p++) p,
      });
    } catch (error) {
      await candidate?.dispose();
      _editingFailure =
          'Editing recovery failed. Saving is disabled; close and reopen the PDF. $error';
      throw StateError(_editingFailure!);
    }
  }

  Future<void> _apply(AnnotationEdit edit, DocumentHistory next) async {
    final model = Map<String, AnnotationRecord>.of(_model!);
    for (final change in edit.changes) {
      if (change.after case final after?) {
        model[change.id] = after;
      } else {
        model.remove(change.id);
      }
    }
    try {
      await lease.use((pdf) => _adapter.apply(pdf, edit));
    } on AnnotationMutationFailure catch (error) {
      if (error.rollbackFailed) await _recover();
      rethrow;
    }
    // No await between committed model/history and render revision publication.
    _model = model;
    _history = next;
    revision++;
    try {
      final reclaimedPages = await lease.use(
        (pdf) => _adapter.collect(pdf, {...model.keys, ...next.referencedIds}),
      );
      await lease.use(
        (pdf) => pdf.reloadPages(
          pageNumbersToReload: {
            ...edit.affectedPages,
            ...reclaimedPages,
          }.toList(),
        ),
      );
    } catch (_) {
      await _recover();
    }
  }

  Future<void> undo() => _travel(redo: false);
  Future<void> redo() => _travel(redo: true);
  Future<void> undoHighlight() => undo();
  Future<void> _travel({required bool redo}) => _lock.synchronized(() async {
    lease.document;
    if (_editingFailure case final failure?) throw StateError(failure);
    final history = _history;
    if (history == null || !(redo ? history.canRedo : history.canUndo)) return;
    final entry = history.entries[redo ? history.cursor : history.cursor - 1];
    final edit = redo
        ? entry.edit
        : AnnotationEdit(
            label: entry.edit.label,
            changes: [
              for (final c in entry.edit.changes.reversed)
                AnnotationChange(id: c.id, before: c.after, after: c.before),
            ],
          );
    await _apply(edit, redo ? history.redo() : history.undo());
  });
  void _checkRevision(int expectedRevision) {
    if (revision != expectedRevision) {
      throw StateError('Annotations changed. Open the menu again.');
    }
  }

  Future<void> highlightUnderline(String id, int argb, int expectedRevision) =>
      _lock.synchronized(() async {
        _checkRevision(expectedRevision);
        await _ensureHistory();
        await _commit(_adapter.highlightUnderline(_model!, id, argb));
      });

  Future<void> recolorHighlights(
    Set<String> ids,
    int argb,
    int expectedRevision,
  ) {
    final frozen = Set<String>.unmodifiable(ids);
    return _lock.synchronized(() async {
      _checkRevision(expectedRevision);
      await _ensureHistory();
      final edit = _adapter.recolor(_model!, frozen, argb);
      if (edit != null) await _commit(edit);
    });
  }

  Future<void> removeAnnotations(Set<String> ids, int expectedRevision) {
    final frozen = Set<String>.unmodifiable(ids);
    return _lock.synchronized(() async {
      _checkRevision(expectedRevision);
      await _ensureHistory();
      await _commit(_adapter.remove(_model!, frozen));
    });
  }

  Future<void> removeHighlight(
    SavedHighlight highlight,
    int expectedRevision,
  ) => _lock.synchronized(() async {
    _checkRevision(expectedRevision);
    await _ensureHistory();
    final target = _model!.values
        .map(_adapter.located)
        .where(
          (a) =>
              a.pageNumber == highlight.pageNumber &&
              a.index == highlight.index,
        );
    if (target.length != 1) throw StateError('Highlight no longer exists.');
    await _commit(_adapter.remove(_model!, {target.single.id}));
  });

  /// [expectedTarget] is captured before the overwrite confirmation for Save As.
  Future<void> save({
    String? destination,
    String? expectedTarget,
  }) => _lock.synchronized(() async {
    lease.document;
    if (_editingFailure case final failure?) throw StateError(failure);
    final access = await DocumentFileAccess.acquire(
      destination ?? path,
      // Save As was authorized by the save panel. Do not follow an old
      // bookmark away from the destination the user just selected.
      restore: destination == null,
    );
    try {
      var target = access.path;
      if (await File(target).exists()) {
        target = await File(target).resolveSymbolicLinks();
      }
      final sameFile = destination == null || p.equals(target, path);
      if (sameFile && !dirty) return;
      final expected = sameFile ? _fingerprint : expectedTarget;
      // Only saving serializes the full PDF. Export removes deleted slots.
      final bytes = dirty ? await lease.use(_adapter.export) : _savedBytes;
      // Validate output before touching any existing file.
      final check = await PdfDocument.openData(
        bytes,
        sourceName: 'save-validation',
        useProgressiveLoading: false,
      );
      try {
        if (check.pages.length != lease.document.pages.length ||
            bytes.length < 8) {
          throw StateError(
            'PDF validation failed. The original file was preserved.',
          );
        }
      } finally {
        await check.dispose();
      }
      await AtomicPdfFile.write(target, bytes, expectedFingerprint: expected);
      path = target;
      _fingerprint = sha256.convert(bytes).toString();
      _savedBytes = bytes;
      _history = _history?.markSaved();
      fileAccessWarning = null;
      try {
        await DocumentFileAccess.remember(target);
      } catch (e) {
        // The PDF is already committed. Do not report a failed save or retain
        // dirty state merely because its permission could not be persisted.
        fileAccessWarning =
            'PDF saved, but access could not be remembered. '
            'Use Locate PDF after reopening PoDoFo: $e';
      }
    } finally {
      await access.release();
    }
  });

  Future<void> close({bool discard = false}) => _lock.synchronized(() {
    if (dirty && !discard) {
      throw StateError('Save or discard changes before closing.');
    }
    lease.close();
  });
}

class AtomicPdfFile {
  static Future<String?> fingerprint(String path) async {
    final file = File(path);
    if (!await file.exists()) return null;
    return (await sha256.bind(file.openRead()).first).toString();
  }

  static Future<void> write(
    String target,
    Uint8List bytes, {
    required String? expectedFingerprint,
  }) async {
    Future<void> check() async {
      if (await fingerprint(target) != expectedFingerprint) {
        throw StateError(
          'The file changed outside PoDoFo. Use Save As to keep both versions.',
        );
      }
    }

    await check();
    // A unique same-filesystem directory makes staging collision-free.
    final staging = await DocumentFileAccess.stagingDirectory(target);
    final temporary = File(p.join(staging.path, 'document.pdf'));
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      await check();
      await temporary.rename(target);
    } finally {
      // Only our uniquely-created staging directory is removed.
      try {
        await staging.delete(recursive: true);
      } on FileSystemException {
        /* Cleanup cannot turn a committed save into a failed save. */
      }
    }
  }
}
