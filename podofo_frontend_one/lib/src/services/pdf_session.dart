import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';
import 'package:synchronized/synchronized.dart';

import '../data/pdf_document_lease.dart';
import 'pdf_highlights.dart';
import 'document_file_access.dart';

/// A tab owns one detached PDF, so replacing its source file is safe on Windows.
/// Mutations, saves, and close are serialized. Failed saves retain dirty edits.
class PdfSession {
  PdfSession._(this.path, this.lease, this._fingerprint, this._savedBytes);
  String path;
  final PdfDocumentLease lease;
  String _fingerprint;
  Uint8List _savedBytes;
  final Lock _lock = Lock();
  String? fileAccessWarning;
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

  static Future<PdfSession> open(String path, {bool selected = false}) async {
    final access = await DocumentFileAccess.acquire(path, selected: selected);
    try {
      // Resolve only after restoring sandbox access, including moved bookmarks.
      path = await File(access.path).resolveSymbolicLinks();
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
    } finally {
      await access.release();
    }
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
  Future<void> save({
    String? destination,
    String? expectedTarget,
  }) => _lock.synchronized(() async {
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
