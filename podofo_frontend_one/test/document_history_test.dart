import 'package:flutter_test/flutter_test.dart';
import 'package:podofo_one/src/editing/annotation_edit.dart';
import 'package:podofo_one/src/editing/document_history.dart';

AnnotationRecord record(String id, {List<List<double>>? quads}) =>
    AnnotationRecord(
      id: id,
      pageNumber: 1,
      index: 0,
      contents: '',
      author: '',
      pdfName: '',
      flags: 4,
      argb: 0xffffff00,
      hasAppearance: false,
      quads: quads ?? [],
    );
AnnotationEdit edit(String label) => AnnotationEdit(
  label: label,
  changes: [AnnotationChange(id: label, after: record(label))],
);

void main() {
  test('undo/redo and saved marker use state identity across branches', () {
    var history = DocumentHistory();
    history = history.commit(edit('one')).markSaved();
    final saved = history.currentId;
    history = history.commit(edit('two'));
    expect(history.undoLabel, 'two');
    history = history.undo();
    expect(history.currentId, saved);
    expect(history.dirty, false);
    expect(history.redoLabel, 'two');
    history = history.redo();
    expect(history.currentId, 2);
    history = history.undo().undo();
    expect(history.dirty, true);
    history = history.commit(edit('different one'));
    expect(history.currentId, isNot(saved));
    expect(history.dirty, true);
    expect(history.canRedo, false);
    expect(history.undo().currentId, 0);
  });

  test(
    'budget failures preserve state and redo; limits retain current model',
    () {
      var history = DocumentHistory(byteLimit: 1600, entryLimit: 2);
      history = history.commit(edit('1')).commit(edit('2')).markSaved();
      history = history.commit(edit('3'));
      expect(history.entries.length, 2);
      expect(history.retainedBytes, lessThanOrEqualTo(1600));
      history = history.undo();
      expect(history.dirty, false);
      expect(() => history.commit(edit('x' * 2000)), throwsStateError);
      expect(history.canRedo, true);
      expect(history.redo().currentId, 3);
      expect(history.undo().undo().currentId, 1);
    },
  );

  test('records and changes are detached and deeply immutable', () {
    final points = <double>[1, 2, 3, 4, 5, 6, 7, 8];
    final quads = [points];
    final annotation = record('a', quads: quads);
    final changes = [AnnotationChange(id: 'a', after: annotation)];
    final action = AnnotationEdit(label: 'Add', changes: changes);
    points[0] = 99;
    quads.clear();
    changes.clear();
    expect(action.changes.single.after!.quads.single.first, 1);
    expect(() => annotation.quads.single[0] = 9, throwsUnsupportedError);
    expect(() => action.changes.clear(), throwsUnsupportedError);
    expect(
      () => AnnotationEdit(
        label: 'bad',
        changes: [
          AnnotationChange(id: 'a', after: annotation),
          AnnotationChange(id: 'a', before: annotation),
        ],
      ),
      throwsArgumentError,
    );
    expect(
      () => AnnotationEdit(
        label: 'bad',
        changes: [AnnotationChange(id: 'different', after: annotation)],
      ),
      throwsArgumentError,
    );
  });
}
