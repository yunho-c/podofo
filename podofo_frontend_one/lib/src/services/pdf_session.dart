import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';
import 'package:synchronized/synchronized.dart';

import '../data/pdf_document_lease.dart';
import 'pdf_highlights.dart';
import 'pdf_navigation_history.dart';

/// A tab owns one detached PDF, so replacing its source file is safe on Windows.
/// Mutations, saves, and close are serialized. Failed saves retain dirty edits.
class PdfSession {
  PdfSession._(this.path, this.lease, this._fingerprint, this._savedBytes);
  String path;
  final PdfDocumentLease lease;
  final navigationHistory = PdfNavigationHistory();
  String _fingerprint;
  Uint8List _savedBytes;
  final Lock _lock = Lock();
  int revision = 0;
  int _savedRevision = 0;
  final _undo = <List<AddedHighlight>>[];
  bool get dirty => revision != _savedRevision;
  bool get canUndo => _undo.isNotEmpty;
  Future<void> waitForIdle() => _lock.synchronized(() {});
  String get cacheKey => '$_fingerprint-$revision';

  /// Short extraction/snapshot work shares the edit/save/close serialization.
  /// Callers must return detached values and release this lock before playback.
  Future<T> readLocked<T>(Future<T> Function(PdfDocument) read) =>
      _lock.synchronized(() => lease.use(read));

  static Future<PdfSession> open(String path) async {
    path = p.normalize(p.absolute(path));
    // Resolve links so Save updates the same file Open read, not a link entry.
    path = await File(path).resolveSymbolicLinks();
    final bytes = await File(path).readAsBytes();
    final pdf = await PdfDocument.openData(
      bytes,
      sourceName: path,
      useProgressiveLoading: false,
    );
    return PdfSession._(
      path,
      PdfDocumentLease(pdf),
      sha256.convert(bytes).toString(),
      bytes,
    );
  }

  Future<void> highlight(List<HighlightRegion> regions, int argb) =>
      _lock.synchronized(() async {
        final result = await lease.use(
          (pdf) => PdfHighlights.add(pdf, regions, argb),
        );
        _undo.add(result);
        revision++;
        await lease.use(
          (pdf) => pdf.reloadPages(
            pageNumbersToReload: result
                .map((a) => a.pageNumber)
                .toSet()
                .toList(),
          ),
        );
      });

  Future<void> undoHighlight() => _lock.synchronized(() async {
    if (_undo.isEmpty) return;
    final added = _undo.last;
    await lease.use((pdf) => PdfHighlights.remove(pdf, added));
    _undo.removeLast();
    revision++;
    await lease.use(
      (pdf) => pdf.reloadPages(
        pageNumbersToReload: added.map((a) => a.pageNumber).toSet().toList(),
      ),
    );
  });

  Future<void> removeHighlight(
    SavedHighlight highlight,
    int expectedRevision,
  ) => _lock.synchronized(() async {
    if (revision != expectedRevision) {
      throw StateError('Highlights changed. Select the highlight again.');
    }
    await lease.use(
      (pdf) => PdfHighlights.remove(pdf, [
        (pageNumber: highlight.pageNumber, index: highlight.index),
      ]),
    );
    _undo.clear(); // Annotation indices change when an arbitrary item is removed.
    revision++;
    await lease.use(
      (pdf) => pdf.reloadPages(pageNumbersToReload: [highlight.pageNumber]),
    );
  });

  /// [expectedTarget] is captured before the overwrite confirmation for Save As.
  Future<void> save({String? destination, String? expectedTarget}) =>
      _lock.synchronized(() async {
        var target = p.normalize(p.absolute(destination ?? path));
        if (await File(target).exists()) {
          target = await File(target).resolveSymbolicLinks();
        }
        final sameFile = p.equals(target, path);
        if (sameFile && !dirty) return;
        final expected = sameFile ? _fingerprint : expectedTarget;
        // Clean copies retain signatures, encryption, and byte-level structure.
        final bytes = dirty
            ? await lease.use((pdf) => pdf.encodePdf())
            : _savedBytes;
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
        _savedRevision = revision;
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
    final staging = await Directory(p.dirname(target))
        .createTemp('.podofo-save-');
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
