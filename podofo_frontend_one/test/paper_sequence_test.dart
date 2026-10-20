import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:podofo_one/objectbox.g.dart';
import 'package:podofo_one/src/narration/paper_plan.dart';
import 'package:podofo_one/src/narration/paper_sequence.dart';
import 'package:podofo_one/src/services/narration_bookmarks.dart';
import 'package:podofo_one/src/services/pdf_session.dart';

import 'fixtures/narration_pdf_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('podofo-paper-sequence-');
    await pdfrxInitialize(tmpPath: directory.path);
  });
  tearDownAll(() async {
    await PdfrxEntryFunctions.instance.stopBackgroundWorker();
    await directory.delete(recursive: true);
  });

  test('real two-column PDF is ordered by geometry and retains both columns', () async {
    final stream = [
      for (var i = 0; i < 5; i++) ...[
        'BT /F1 12 Tf 40 ${700 - i * 18} Td (Left sentence $i.) Tj ET\n',
        'BT /F1 12 Tf 340 ${700 - i * 18} Td (Right sentence $i.) Tj ET\n',
      ],
    ].join();
    final file = File('${directory.path}/columns.pdf')
      ..writeAsBytesSync(narrationPdfFixture([stream]));
    final session = await PdfSession.open(file.path);
    final sequence = PaperSequence(session, const PaperReadOptions());
    try {
      final plan = await sequence.preview(1);
      expect(plan.issue, isNull);
      expect(plan.description, contains('Two columns'));
      expect(
        plan.passages.map((p) => p.text).join(' '),
        '${[for (var i = 0; i < 5; i++) 'Left sentence $i.'].join(' ')} ${[for (var i = 0; i < 5; i++) 'Right sentence $i.'].join(' ')}',
      );
    } finally {
      sequence.close();
      await session.close();
    }
  });

  test('whole-paper navigation keeps two cached pages and stops explicitly at scanned pages', () async {
    final file = File('${directory.path}/paper.pdf')
      ..writeAsBytesSync(
        narrationPdfFixture([
          for (var i = 1; i <= 24; i++)
            i == 12
                ? ''
                : 'BT /F1 18 Tf 60 700 Td (Page $i. A complete passage.) Tj ET\n',
        ]),
      );
    final session = await PdfSession.open(file.path);
    final sequence = PaperSequence(session, const PaperReadOptions());
    try {
      expect((await sequence.start())!.text, startsWith('Page 1.'));
      for (var i = 2; i <= 24; i++) {
        if (i == 12) {
          await expectLater(
            sequence.move(1),
            throwsA(isA<PaperReviewRequired>()),
          );
          expect(sequence.review!.page.page, 12);
          sequence.skipReview();
          continue;
        }
        expect((await sequence.move(1))!.text, startsWith('Page $i.'));
        expect(sequence.cachedPageCount, lessThanOrEqualTo(2));
      }
      expect(await sequence.move(1), isNull);
      expect((await sequence.move(-1))!.text, startsWith('Page 23.'));
      expect(sequence.cachedPageCount, 2);
    } finally {
      sequence.close();
      await session.close();
    }
    expect(sequence.cachedPageCount, 0);
  });

  test('source bookmarks survive reopen and copy; changed text rejects stale resume', () async {
    final file = File('${directory.path}/resume.pdf')
      ..writeAsBytesSync(
        narrationPdfFixture([
          'BT /F1 18 Tf 60 700 Td (First sentence. Second sentence.) Tj ET\n',
        ]),
      );
    var session = await PdfSession.open(file.path);
    final canonical = session.path;
    final sequence = PaperSequence(session, const PaperReadOptions());
    final passage = (await sequence.start())!;
    final anchor = passage.anchorAt(passage.text.indexOf('Second'))!;
    var store = Store(getObjectBoxModel(), directory: '${directory.path}/db');
    NarrationBookmarks(store).save(canonical, anchor);
    store.close();
    sequence.close();
    await session.close();
    store = Store(getObjectBoxModel(), directory: '${directory.path}/db');
    session = await PdfSession.open(canonical);
    try {
      final bookmarks = NarrationBookmarks(store);
      final saved = bookmarks.find(canonical)!;
      final resumed = PaperSequence(session, const PaperReadOptions());
      expect(
        (await resumed.start(anchor: saved.anchor))!.text,
        'Second sentence.',
      );
      resumed.close();
      bookmarks.copy(canonical, '$canonical.copy');
      expect(bookmarks.find('$canonical.copy')!.anchor.offset, anchor.offset);
      expect(bookmarks.find(canonical)!.id, saved.id);
      expect(bookmarks.find('$canonical.copy')!.id, isNot(saved.id));
    } finally {
      await session.close();
      store.close();
    }
    await file.writeAsBytes(
      narrationPdfFixture([
        'BT /F1 18 Tf 60 700 Td (Changed content.) Tj ET\n',
      ]),
    );
    session = await PdfSession.open(canonical);
    final stale = PaperSequence(session, const PaperReadOptions());
    try {
      await expectLater(stale.start(anchor: anchor), throwsStateError);
    } finally {
      stale.close();
      await session.close();
    }
  });
}
