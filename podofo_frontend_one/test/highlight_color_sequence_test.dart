import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:podofo_one/src/editing/pdf_annotation_adapter.dart';
import 'package:podofo_one/src/services/highlight_color_sequence.dart';
import 'package:podofo_one/src/services/pdf_highlights.dart';
import 'package:podofo_one/src/services/pdf_session.dart';

import 'fixtures/pdf_fixture.dart';

const _first = 0x66ff0000, _second = 0x6600ff00, _third = 0x660000ff;
const _regions = [
  HighlightRegion(1, [PdfRect(20, 120, 130, 100)]),
  HighlightRegion(2, [PdfRect(20, 120, 130, 100)]),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporary;
  var serial = 0;
  setUpAll(() async {
    temporary = await Directory.systemTemp.createTemp('podofo-color-sequence-');
    await pdfrxInitialize(tmpPath: temporary.path);
  });
  tearDownAll(() async {
    await PdfrxEntryFunctions.instance.stopBackgroundWorker();
    await temporary.delete(recursive: true);
  });
  Future<PdfSession> open({AnnotationFaults? faults}) async {
    final file = File('${temporary.path}/${serial++}.pdf');
    await file.writeAsBytes(pdfFixture());
    final session = await PdfSession.open(
      file.path,
      annotationAdapter: PdfAnnotationAdapter(faults: faults),
    );
    addTearDown(() => session.close(discard: true));
    return session;
  }

  HighlightColorSequence sequence(List<Object> errors, {bool save = false}) =>
      HighlightColorSequence(
        recolor: (target, color, isActive) async {
          final result = await target.session.recolorHighlights(
            target.ids,
            color,
            target.revision,
            isActive: isActive,
          );
          if (save && result != null) await target.session.save();
          return result;
        },
        onError: errors.add,
      );

  test(
    'rapid colors target all created pages with separate saved undo steps',
    () async {
      final s = await open();
      final older = (await s.highlight([_regions.first], 0x66aaaaaa))!;
      final errors = <Object>[];
      final keys = sequence(errors, save: true);
      final ready = Completer<HighlightTarget?>();
      keys.start(() => ready.future);
      expect(keys.choose(_second), true);
      expect(keys.choose(_third), true);
      expect(keys.choose(_third), true); // no extra history for the same color
      final created = (await s.highlight(_regions, _first))!;
      await s.save(); // saving the first color must not invalidate the receipt
      ready.complete(created);
      await keys.waitForIdle();
      expect(errors, isEmpty);
      expect(keys.active, true);
      expect(s.revision, 4); // older + creation + two color changes
      expect(s.dirty, false);
      expect(created.ids, hasLength(2));
      expect(() => created.ids.clear(), throwsUnsupportedError);
      Future<void> colors(int color) async {
        final records = await s.annotations();
        expect(
          records.where((a) => created.ids.contains(a.id)).map((a) => a.argb),
          everyElement(color),
        );
        expect(
          records.singleWhere((a) => older.ids.contains(a.id)).argb,
          0x66aaaaaa,
        );
      }

      await colors(_third);
      final reopened = await PdfSession.open(s.path);
      try {
        expect(
          (await reopened.annotations()).map((a) => a.argb),
          unorderedEquals([0x66aaaaaa, _third, _third]),
        );
      } finally {
        await reopened.close(discard: true);
      }
      await s.undo();
      await colors(_second);
      expect(s.dirty, true);
      await s.undo();
      await colors(_first);
      await s.undo();
      expect((await s.annotations()).single.id, older.ids.single);
      await s.redo();
      await colors(_first);
      await s.redo();
      await colors(_second);
      await s.redo();
      await colors(_third);
      expect(s.dirty, false);
    },
  );

  test(
    'cancelled pending creation cannot color or cancel a newer sequence',
    () async {
      final s = await open();
      final errors = <Object>[];
      final keys = sequence(errors);
      final ready = Completer<HighlightTarget?>();
      keys.start(() => ready.future);
      keys.choose(_second);
      final oldWork = keys.waitForIdle();
      final first = (await s.highlight([_regions.first], _first))!;
      keys.cancel();
      keys.start(() => s.highlight([_regions.last], _first));
      keys.choose(_third);
      ready.complete(first);
      await oldWork;
      await keys.waitForIdle();
      final records = await s.annotations();
      expect(records.singleWhere((a) => first.ids.contains(a.id)).argb, _first);
      expect(
        records.singleWhere((a) => !first.ids.contains(a.id)).argb,
        _third,
      );
      expect(s.revision, 3);
      expect(keys.active, true);
      expect(errors, isEmpty);
    },
  );

  test(
    'cancellation is rechecked after waiting for the document lock',
    () async {
      final s = await open();
      final errors = <Object>[];
      final keys = sequence(errors);
      keys.start(() => s.highlight(_regions, _first));
      await keys.waitForIdle();
      final entered = Completer<void>(), release = Completer<void>();
      final blocker = s.readLocked((_) async {
        entered.complete();
        await release.future;
      });
      await entered.future;
      keys.choose(_second);
      final pending = keys.waitForIdle();
      await Future<void>.delayed(Duration.zero);
      keys.cancel();
      release.complete();
      await blocker;
      await pending;
      expect(s.revision, 1);
      expect((await s.annotations()).map((a) => a.argb), everyElement(_first));
      expect(errors, isEmpty);
    },
  );

  test('undo/redo or another edit invalidates the previous target', () async {
    final s = await open();
    final errors = <Object>[];
    final keys = sequence(errors);
    keys.start(() => s.highlight(_regions, _first));
    await keys.waitForIdle();
    await s.undo();
    await s.redo();
    keys.choose(_third);
    await keys.waitForIdle();
    expect(keys.active, false);
    expect(s.revision, 3);
    expect((await s.annotations()).map((a) => a.argb), everyElement(_first));
    keys.start(() => s.highlight(_regions, _second));
    await keys.waitForIdle();
    await s.underline([_regions.first]);
    keys.choose(_third);
    await keys.waitForIdle();
    expect(s.revision, 5);
    expect(keys.active, false);
    expect(errors, isEmpty);
  });

  test(
    'failed recoloring rolls back, reports once and drops later choices',
    () async {
      final faults = AnnotationFaults();
      final s = await open(faults: faults);
      final errors = <Object>[];
      final keys = sequence(errors);
      keys.start(() => s.highlight(_regions, _first));
      await keys.waitForIdle();
      await s.save();
      faults.failAfterChanges = 1;
      keys.choose(_second);
      keys.choose(_third);
      await keys.waitForIdle();
      expect(errors, hasLength(1));
      expect(keys.active, false);
      expect(s.revision, 1);
      expect(s.dirty, false);
      expect((await s.annotations()).map((a) => a.argb), everyElement(_first));
    },
  );

  test(
    'no selection, failed creation and a closed session leave no target',
    () async {
      final s = await open();
      final errors = <Object>[];
      final keys = sequence(errors);
      expect(keys.choose(_second), false);
      keys.start(() => s.highlight([], _first));
      keys.choose(_second);
      await keys.waitForIdle();
      expect(keys.active, false);
      keys.start(() => throw StateError('creation failed'));
      await keys.waitForIdle();
      expect(keys.active, false);
      expect(errors, hasLength(1));
      keys.start(() => s.highlight(_regions, _first));
      await keys.waitForIdle();
      await s.close(discard: true);
      keys.choose(_second);
      await keys.waitForIdle();
      expect(keys.active, false);
      expect(errors, hasLength(1));
    },
  );
}
