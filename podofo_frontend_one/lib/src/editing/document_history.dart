import 'dart:collection';

import 'annotation_edit.dart';

class HistoryEntry {
  const HistoryEntry(this.edit, this.beforeId, this.afterId);
  final AnnotationEdit edit;
  final int beforeId, afterId;
}

/// Immutable delta history. The document model is owned separately by the session;
/// entries contain only affected records, never PDFs or whole model snapshots.
class DocumentHistory {
  DocumentHistory({this.byteLimit = 64 * 1024 * 1024, this.entryLimit = 100})
    : entries = const [],
      cursor = 0,
      currentId = 0,
      savedStateId = 0,
      _nextId = 1 {
    if (byteLimit < 1 || entryLimit < 1) {
      throw ArgumentError('Invalid history limits.');
    }
  }
  DocumentHistory._(
    Iterable<HistoryEntry> entries,
    this.cursor,
    this.currentId,
    this.savedStateId,
    this._nextId,
    this.byteLimit,
    this.entryLimit,
  ) : entries = List.unmodifiable(entries);
  final List<HistoryEntry> entries;
  final int cursor, currentId, savedStateId, _nextId, byteLimit, entryLimit;
  bool get dirty => currentId != savedStateId;
  bool get canUndo => cursor > 0;
  bool get canRedo => cursor < entries.length;
  String? get undoLabel => canUndo ? entries[cursor - 1].edit.label : null;
  String? get redoLabel => canRedo ? entries[cursor].edit.label : null;
  Set<String> get referencedIds => {
    for (final entry in entries)
      for (final change in entry.edit.changes) change.id,
  };
  static int _bytes(Iterable<HistoryEntry> entries) {
    final records = HashSet<AnnotationRecord>.identity();
    var overhead = 0;
    for (final entry in entries) {
      overhead +=
          96 + entry.edit.label.length * 2 + entry.edit.changes.length * 64;
      for (final change in entry.edit.changes) {
        if (change.before case final record?) records.add(record);
        if (change.after case final record?) records.add(record);
      }
    }
    return overhead +
        records.fold(0, (sum, record) => sum + record.retainedBytes);
  }

  int get retainedBytes => _bytes(entries);

  DocumentHistory commit(AnnotationEdit edit) {
    final retained = [
      ...entries.take(cursor),
      HistoryEntry(edit, currentId, _nextId),
    ];
    while (retained.length > 1 &&
        (retained.length > entryLimit || _bytes(retained) > byteLimit)) {
      retained.removeAt(0);
    }
    if (_bytes(retained) > byteLimit) {
      throw StateError(
        'This edit exceeds the annotation undo budget. The PDF was not changed.',
      );
    }
    return DocumentHistory._(
      retained,
      retained.length,
      _nextId,
      savedStateId,
      _nextId + 1,
      byteLimit,
      entryLimit,
    );
  }

  DocumentHistory undo() => !canUndo
      ? this
      : DocumentHistory._(
          entries,
          cursor - 1,
          entries[cursor - 1].beforeId,
          savedStateId,
          _nextId,
          byteLimit,
          entryLimit,
        );
  DocumentHistory redo() => !canRedo
      ? this
      : DocumentHistory._(
          entries,
          cursor + 1,
          entries[cursor].afterId,
          savedStateId,
          _nextId,
          byteLimit,
          entryLimit,
        );
  DocumentHistory markSaved() => DocumentHistory._(
    entries,
    cursor,
    currentId,
    currentId,
    _nextId,
    byteLimit,
    entryLimit,
  );
}
