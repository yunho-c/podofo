import 'dart:io';
import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:podofo_one/objectbox.g.dart';
import 'package:podofo_one/src/narration/paper_plan.dart';
import 'package:podofo_one/src/narration/paper_sequence.dart';
import 'package:podofo_one/src/narration/narration_controller.dart';
import 'package:podofo_one/src/narration/narrator.dart';
import 'package:podofo_one/src/services/narration_bookmarks.dart';
import 'package:podofo_one/src/services/pdf_session.dart';
import 'package:podofo_one/src/services/pdf_highlights.dart';

import 'fixtures/narration_pdf_fixture.dart';
import 'support/fake_narrator.dart';

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

  test('paper corpus excludes confirmed margins, preserves scientific text and prepares ahead without advancing', () async {
    String margins(int n) =>
        'BT /F1 9 Tf 40 770 Td (${n.isOdd ? 'Methods for measured results' : 'A reproducible paper'}) Tj ET\n'
        'BT /F1 9 Tf 295 65 Td ($n) Tj ET\n';
    final file = File('${directory.path}/corpus.pdf')
      ..writeAsBytesSync(
        narrationPdfFixture([
          '${margins(1)}'
              'BT /F1 18 Tf 40 720 Td (Introduction) Tj ET\n'
              'BT /F1 12 Tf 40 690 Td (We study inter-) Tj ET\n'
              'BT /F1 12 Tf 40 672 Td (national data. International results agree.) Tj ET\n'
              'BT /F1 12 Tf 40 610 Td (The next page continues this) Tj ET\n',
          '${margins(2)}'
              'BT /F1 12 Tf 40 700 Td (sentence without losing text.) Tj ET\n'
              'BT /F1 12 Tf 40 650 Td (Eq. \\(1\\) and 3.14 remain literal.) Tj ET\n',
          '${margins(3)}${[for (var i = 0; i < 5; i++) 'BT /F1 12 Tf 40 ${700 - 18 * i} Td (Left experiment $i.) Tj ET\n'
                'BT /F1 12 Tf 340 ${700 - 18 * i} Td (Right observation $i.) Tj ET\n'].join()}',
          '${margins(4)}BT /F1 18 Tf 40 700 Td (References) Tj ET\n'
              'BT /F1 12 Tf 40 660 Td (Citation content.) Tj ET\n',
        ]),
      );
    final session = await PdfSession.open(file.path);
    final sequence = PaperSequence(session, const PaperReadOptions());
    try {
      final first = await sequence.preview(1);
      expect(
        first.blocks.where(
          (b) => b.kind == PaperBlockKind.runningMatter && !b.included,
        ),
        hasLength(2),
      );
      expect(first.blocks.any((b) => b.kind == PaperBlockKind.heading), true);
      expect(
        first.passages.map((p) => p.text).join(' '),
        'Introduction We study international data. International results agree. The next page continues this',
      );
      final included = await sequence.preview(
        1,
        preferences: const PaperReadOptions(skipRunningMatter: false),
      );
      expect(
        included.passages.map((p) => p.text).join(' '),
        contains('Methods for measured results'),
      );
      expect((await sequence.start())!.text, 'Introduction');
      await sequence.indexDocument();
      expect(sequence.cachedPageCount, 1);
      expect(sequence.pageNumber, 1);
      expect(sequence.index.snapshot.fullyResolved, true);
      expect(sequence.index.snapshot.scopeEndPage, 4);
      for (final indexed in sequence.index.snapshot.pages) {
        final planned = await sequence.preview(indexed.page);
        expect(indexed.textHash, planned.page.textHash);
        expect(indexed.endsPaper, planned.endsPaper);
        expect(indexed.passages, hasLength(planned.passages.length));
        for (var i = 0; i < planned.passages.length; i++) {
          final passage = planned.passages[i], descriptor = indexed.passages[i];
          expect(descriptor.ordinal, i);
          expect(descriptor.anchor.offset, passage.anchorAt(0)!.offset);
          expect(descriptor.utf16Length, passage.text.length);
          expect(
            descriptor.spokenTextHash,
            sha256.convert(utf8.encode(passage.text)).toString(),
          );
        }
      }
      await sequence.prepareNext();
      expect(sequence.pageNumber, 1);
      expect(sequence.cachedPageCount, 2);
      final text = <String>[];
      for (
        var passage = await sequence.move(1);
        passage != null;
        passage = await sequence.move(1)
      ) {
        text.add(passage.text);
        await sequence.prepareNext();
        expect(sequence.cachedPageCount, lessThanOrEqualTo(2));
      }
      final complete = text.join(' ');
      expect(
        complete,
        contains('The next page continues this sentence without losing text.'),
      );
      expect(complete, contains('Eq. (1) and 3.14 remain literal.'));
      expect(
        complete,
        contains(
          '${[for (var i = 0; i < 5; i++) 'Left experiment $i.'].join(' ')} ${[for (var i = 0; i < 5; i++) 'Right observation $i.'].join(' ')}',
        ),
      );
      expect(complete, isNot(contains('Citation content')));
      expect(complete, isNot(contains('reproducible paper')));
    } finally {
      sequence.close();
      await session.close();
    }
  });

  test('Unicode index identities survive annotation save and Save As without rebuilding', () async {
    final file = File('${directory.path}/index-save.pdf')
      ..writeAsBytesSync(
        narrationPdfFixture([
          for (var i = 0; i < 3; i++) 'BT /F1 12 Tf 40 700 Td (A B C.) Tj ET\n',
        ], unicodeMap: narrationUnicodeMap),
      );
    final session = await PdfSession.open(file.path);
    final sequence = PaperSequence(session, const PaperReadOptions());
    try {
      final passage = (await sequence.start())!;
      expect(passage.text, '🚀 fi é.');
      await sequence.indexDocument();
      final before = sequence.index.snapshot;
      final id = before.passages.first.id;
      final descriptor = before.passages.first;
      expect(descriptor.utf16Length, passage.text.length);
      expect(descriptor.scalarCount, passage.text.runes.length);
      expect(descriptor.anchor.textHash, passage.anchorAt(0)!.textHash);
      await session.highlight([
        const HighlightRegion(1, [PdfRect(40, 710, 100, 690)]),
      ], 0x88ffff00);
      await session.save();
      await session.save(destination: '${directory.path}/index-copy.pdf');
      final extractions = sequence.planner.extractionCount;
      await sequence.indexDocument();
      expect(sequence.planner.extractionCount, extractions);
      expect(identical(sequence.index.snapshot, before), true);
      // Evict the first detailed page, then verify fresh extraction after saves.
      await sequence.start(page: 2);
      await sequence.start(page: 3);
      expect((await sequence.start())!.text, passage.text);
      expect(sequence.index.page(1)!.passages.first.id, id);
      expect(sequence.index.revision, before.revision);
    } finally {
      sequence.close();
      await session.close(discard: true);
    }
  });

  test('cancelled preparation cannot publish stale pages or remove replacement work', () async {
    final file = File('${directory.path}/prefetch.pdf')
      ..writeAsBytesSync(
        narrationPdfFixture([
          'BT /F1 12 Tf 40 700 Td (First page.) Tj ET\n',
          'BT /F1 12 Tf 40 700 Td (Second page.) Tj ET\n',
        ]),
      );
    final session = await PdfSession.open(file.path);
    final sequence = PaperSequence(session, const PaperReadOptions());
    final release = Completer<void>(), entered = Completer<void>();
    try {
      await sequence.start();
      final lock = session.readLocked((_) {
        entered.complete();
        return release.future;
      });
      await entered.future;
      final stale = expectLater(sequence.prepareNext(), throwsStateError);
      sequence.cancelPending();
      final replacement = sequence.prepareNext();
      release.complete();
      await Future.wait([lock, stale, replacement]);
      expect(sequence.pageNumber, 1);
      expect(sequence.cachedPageCount, 2);
      expect((await sequence.move(1))!.text, 'Second page.');
    } finally {
      if (!release.isCompleted) release.complete();
      sequence.close();
      await session.close();
    }
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
    final engine = FakeNarratorSession();
    final controller = NarrationController(
      open: (_) async => engine,
      onPosition: (_, anchor) =>
          NarrationBookmarks(store).save(canonical, anchor),
    );
    try {
      await controller.read(
        session,
        () async => NarrationSource(
          documentId: session,
          title: 'Resume fixture',
          text: passage.text,
          passage: passage,
          sequence: sequence,
        ),
      );
      engine.playbacks.single.events.add(
        NarrationSnapshot(
          phase: NarrationPhase.playing,
          start: passage.text.indexOf('Second'),
          end: passage.text.length,
        ),
      );
      await controller.stop();
      await controller.closeDocument(session);
      expect(NarrationBookmarks(store).find(canonical)!.offset, anchor.offset);
    } finally {
      await controller.close();
    }
    store.close();
    sequence.close();
    await session.close();
    store = Store(getObjectBoxModel(), directory: '${directory.path}/db');
    session = await PdfSession.open(canonical);
    try {
      final bookmarks = NarrationBookmarks(store);
      final saved = bookmarks.find(canonical)!;
      expect(saved.contextAfter, 'Second sentence.');
      expect(saved.contextBefore, 'First sentence. ');
      expect(saved.planVersion, PaperPlanner.version);
      final resumed = PaperSequence(session, const PaperReadOptions());
      expect(
        (await resumed.start(anchor: saved.anchor))!.text,
        'Second sentence.',
      );
      resumed.close();
      bookmarks.copy(canonical, '$canonical.copy');
      expect(bookmarks.find('$canonical.copy')!.anchor.offset, anchor.offset);
      expect(
        bookmarks.find('$canonical.copy')!.contextAfter,
        saved.contextAfter,
      );
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
