import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:podofo_one/src/narration/narration_controller.dart';
import 'package:podofo_one/src/narration/narrator.dart';
import 'package:podofo_one/src/narration/paper_index.dart';
import 'package:podofo_one/src/narration/paper_page_planner.dart';
import 'package:podofo_one/src/narration/paper_plan.dart';
import 'package:podofo_one/src/narration/paper_sequence.dart';
import 'package:podofo_one/src/narration/pdf_text_repository.dart';
import 'package:podofo_one/src/narration/source_map.dart';

import 'support/fake_narrator.dart';

ExtractedPaperPage page(int number, {String? text, bool header = false}) {
  final body = text ?? 'Page $number. A complete sentence.';
  final value = header ? 'Repeated title\n$body' : body;
  return ExtractedPaperPage(
    PdfTextSnapshot(
      page: number,
      text: value,
      boxes: [
        for (var i = 0; i < value.length; i++)
          PdfRect(
            40 + (header && i > 14 ? i - 15 : i) * 6.0,
            header && i < 14 ? 780 : 700,
            46 + (header && i > 14 ? i - 15 : i) * 6.0,
            header && i < 14 ? 770 : 690,
          ),
      ],
    ),
    600,
    800,
  );
}

PaperSequence sequence(
  int count, {
  Future<ExtractedPaperPage> Function(int)? extract,
  PaperReadOptions options = const PaperReadOptions(),
}) => PaperSequence.withPlanner(
  PaperPagePlanner(pageCount: count, extract: extract ?? (n) async => page(n)),
  options,
);

Future<void> flush() => pumpEventQueue(times: 15);

void main() {
  test('preview is side-effect free; mid-passage start seeds the full page and indexes earlier content', () async {
    final paper = sequence(5);
    addTearDown(paper.close);
    final preview = await paper.preview(3);
    expect(paper.index.snapshot.processedPageCount, 0);
    expect(paper.index.snapshot.status, PaperIndexStatus.idle);
    final whole = preview.passages.single;
    final anchor = whole.anchorAt(whole.text.indexOf('A complete'))!;
    final suffix = await paper.start(page: 3, anchor: anchor);
    expect(suffix!.text, startsWith('A complete'));
    expect(paper.index.page(3)!.passages.single.utf16Length, whole.text.length);
    final first = paper.indexDocument();
    expect(identical(first, paper.indexDocument()), true);
    await first;
    final snapshot = paper.index.snapshot;
    expect(snapshot.pages.map((p) => p.page), [1, 2, 3, 4, 5]);
    expect(snapshot.fullyResolved, true);
    expect(paper.pageNumber, 3);
    expect(paper.review, isNull);
    expect(
      paper.cachedPageCount,
      1,
    ); // Index pages did not populate playback cache.
    expect((await paper.move(1))!.text, startsWith('Page 4.'));
    expect(paper.cachedPageCount, 2);
    final extractions = paper.planner.extractionCount;
    await paper.indexDocument();
    expect(paper.planner.extractionCount, extractions);
  });

  test('descriptors retain normalized Unicode statistics and immutable source identity only', () async {
    final paper = sequence(
      1,
      extract: (n) async => page(n, text: 'A ﬁ 🚀 한글!'),
    );
    addTearDown(paper.close);
    final passage = (await paper.start())!;
    await paper.indexDocument();
    final old = paper.index.snapshot;
    final descriptor = old.passages.single;
    expect(passage.text, 'A fi 🚀 한글!');
    expect(descriptor.utf16Length, passage.text.length);
    expect(descriptor.scalarCount, passage.text.runes.length);
    expect(descriptor.wordCount, 3);
    expect(descriptor.punctuationCount, 1);
    expect(
      descriptor.spokenTextHash,
      sha256.convert(utf8.encode(passage.text)).toString(),
    );
    expect(descriptor.anchor.contextBefore, isEmpty);
    expect(descriptor.anchor.contextAfter, isEmpty);
    final changed = page(1, text: 'Changed content.');
    paper.index.record(
      PaperPlanner.plan(changed.text, paper.options),
      paper.options,
    );
    expect(paper.index.snapshot.passages.single.id, isNot(descriptor.id));
    expect(old.passages.single.id, descriptor.id);
    expect(() => old.pages.clear(), throwsUnsupportedError);
    paper.close();
    expect(paper.index.snapshot.status, PaperIndexStatus.closed);
    expect(paper.index.retainedPageCount, 0);
    expect(old.passages.single.id, descriptor.id);
  });

  test('foreground work interrupts background neighbor scanning with one extraction lane', () async {
    final entered = Completer<void>(), release = Completer<void>();
    final calls = <int>[];
    var blocked = false;
    final planner = PaperPagePlanner(
      pageCount: 4,
      extract: (n) async {
        calls.add(n);
        if (n == 2 && !blocked) {
          blocked = true;
          entered.complete();
          await release.future;
        }
        return page(n, header: true);
      },
    );
    addTearDown(planner.close);
    final background = planner.plan(
      1,
      const PaperReadOptions(),
      priority: PaperPlanPriority.background,
    );
    await entered.future;
    final prefetch = planner.plan(
      3,
      const PaperReadOptions(skipRunningMatter: false),
      priority: PaperPlanPriority.prefetch,
    );
    final foreground = planner.plan(
      4,
      const PaperReadOptions(skipRunningMatter: false),
    );
    release.complete();
    await foreground;
    await prefetch;
    await background;
    expect(calls.take(4), [1, 2, 4, 3]);
    expect(planner.yieldedPlans, 1);
    expect(planner.peakExtractions, 1);
  });

  test('playback promotes and shares an in-flight index page', () async {
    final entered = Completer<void>(), release = Completer<void>();
    final calls = <int>[];
    final planner = PaperPagePlanner(
      pageCount: 2,
      extract: (n) async {
        calls.add(n);
        if (n == 1) {
          entered.complete();
          await release.future;
        }
        return page(n);
      },
    );
    addTearDown(planner.close);
    final background = planner.plan(
      1,
      const PaperReadOptions(),
      priority: PaperPlanPriority.background,
    );
    await entered.future;
    final foreground = planner.plan(1, const PaperReadOptions());
    final next = planner.plan(
      2,
      const PaperReadOptions(),
      priority: PaperPlanPriority.prefetch,
    );
    expect(identical(background, foreground), true);
    release.complete();
    expect(identical(await background, await foreground), true);
    await next;
    expect(calls, [1, 2]);
    expect(planner.yieldedPlans, 0);
    expect(planner.peakExtractions, 1);
  });

  test(
    'cancelled scan cannot publish late pages or clear its replacement',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      var blocked = false;
      final paper = sequence(
        4,
        extract: (n) async {
          if (n == 1 && !blocked) {
            blocked = true;
            entered.complete();
            await release.future;
          }
          return page(n);
        },
      );
      addTearDown(paper.close);
      await paper.start(page: 3);
      final stale = paper.indexDocument();
      await entered.future;
      paper.cancelPending();
      expect(paper.index.snapshot.status, PaperIndexStatus.cancelled);
      expect(paper.index.snapshot.pages.map((p) => p.page), [3]);
      final replacement = paper.indexDocument();
      release.complete();
      await Future.wait([stale, replacement]);
      expect(paper.index.snapshot.fullyResolved, true);
      expect(paper.index.snapshot.status, PaperIndexStatus.scanned);
      expect(paper.index.snapshot.processedPageCount, 4);
      expect(paper.pageNumber, 3);
      expect(paper.planner.peakExtractions, 1);
    },
  );

  test('close rejects an in-flight result, clears metadata and prevents more extraction', () async {
    final entered = Completer<void>(), release = Completer<void>();
    var calls = 0, notifications = 0;
    final paper = sequence(
      100,
      extract: (n) async {
        calls++;
        entered.complete();
        await release.future;
        return page(n);
      },
    );
    paper.index.addListener(() => notifications++);
    final scan = paper.indexDocument();
    await entered.future;
    paper.close();
    final atClose = notifications;
    release.complete();
    await scan;
    await paper.indexDocument();
    expect(calls, 1);
    expect(notifications, atClose);
    expect(paper.index.snapshot.pages, isEmpty);
    expect(paper.cachedPageCount, 0);
    expect(paper.index.snapshot.fullyResolved, false);
  });

  test('failed and scanned pages are unresolved without changing active review; failures retry explicitly', () async {
    var fail = true;
    final paper = sequence(
      4,
      extract: (n) async {
        if (n == 2 && fail) throw StateError('temporary extraction failure');
        return page(n, text: n == 3 ? '' : null);
      },
    );
    addTearDown(paper.close);
    await paper.start();
    await paper.indexDocument();
    expect(paper.index.snapshot.scanFinished, true);
    expect(paper.index.snapshot.fullyResolved, false);
    expect(paper.index.snapshot.unresolvedPages.map((p) => p.page), [2, 3]);
    expect(paper.review, isNull);
    fail = false;
    await paper.indexDocument(retryFailures: true);
    expect(paper.index.snapshot.unresolvedPages.map((p) => p.page), [3]);
    await paper.move(1);
    await expectLater(paper.move(1), throwsA(isA<PaperReviewRequired>()));
    expect(paper.review!.page.page, 3);
    paper.skipReview();
    await paper.indexDocument();
    expect(paper.index.page(3)!.status, PaperIndexPageStatus.skipped);
    expect(paper.index.snapshot.fullyResolved, true);
    expect((await paper.move(1))!.text, startsWith('Page 4.'));
  });

  test(
    'mixed-script text is indexed in PDF order without a layout override',
    () async {
      final paper = sequence(
        3,
        extract: (n) async => page(n, text: n == 2 ? 'مرحبا بالعالم.' : null),
      );
      addTearDown(paper.close);
      await paper.start();
      await paper.indexDocument();
      final id = paper.index.page(1)!.passages.single.id;
      expect(paper.index.snapshot.fullyResolved, true);
      expect((await paper.move(1))!.text, 'مرحبا بالعالم.');
      expect(paper.review, isNull);
      expect(paper.index.page(1)!.passages.single.id, id);
      expect(
        paper.index.page(2)!.passages.single.optionsKey,
        contains('pdfOrder'),
      );
    },
  );

  test('reference scope excludes a later seeded page; changing options invalidates identities', () async {
    final paper = sequence(
      5,
      extract: (n) async => page(n, text: n == 3 ? 'References' : null),
    );
    addTearDown(paper.close);
    await paper.start(page: 5);
    final old = paper.index.snapshot;
    await paper.indexDocument();
    expect(paper.index.snapshot.scopeEndPage, 3);
    expect(paper.index.snapshot.pages.map((p) => p.page), [1, 2, 3]);
    expect(paper.index.snapshot.passages.map((p) => p.page), [1, 2]);
    expect(paper.index.snapshot.fullyResolved, true);
    expect(paper.pageNumber, 5); // Discovery never moves or stops playback.
    final id = paper.index.page(1)!.passages.single.id;
    paper.options = const PaperReadOptions(stopAtReferences: false);
    expect(paper.cachedPageCount, 0);
    await paper.indexDocument();
    expect(paper.index.snapshot.scopeEndPage, 5);
    expect(paper.index.snapshot.processedPageCount, 5);
    expect(paper.index.page(1)!.passages.single.id, isNot(id));
    expect(old.pages.map((p) => p.page), [5]);
  });

  test('option change during extraction cannot publish the old plan', () async {
    final entered = Completer<void>(), release = Completer<void>();
    var first = true;
    final paper = sequence(
      2,
      extract: (n) async {
        if (first) {
          first = false;
          entered.complete();
          await release.future;
        }
        return page(n, text: n == 1 ? 'References' : null);
      },
    );
    addTearDown(paper.close);
    final stale = paper.indexDocument();
    await entered.future;
    paper.options = const PaperReadOptions(stopAtReferences: false);
    final replacement = paper.indexDocument();
    release.complete();
    await Future.wait([stale, replacement]);
    expect(paper.index.snapshot.fullyResolved, true);
    expect(paper.index.snapshot.passages, hasLength(2));
    expect(
      paper.index.snapshot.passages.every(
        (p) => p.revision == paper.index.revision,
      ),
      true,
    );
  });

  test(
    'an earlier unresolved page keeps a known reference boundary provisional',
    () async {
      final paper = sequence(
        5,
        extract: (n) async => page(
          n,
          text: switch (n) {
            1 => '',
            3 => 'References',
            _ => null,
          },
        ),
      );
      addTearDown(paper.close);
      await paper.indexDocument();
      final snapshot = paper.index.snapshot;
      expect(snapshot.scopeEndPage, 3);
      expect(snapshot.scanFinished, true);
      expect(snapshot.fullyResolved, false);
      expect(snapshot.unresolvedPages.map((p) => p.page), [1]);
      expect(paper.index.page(4), isNull);
      expect(paper.review, isNull);
    },
  );

  test('fresh playback extraction replaces changed text metadata without invalidating other pages', () async {
    var changed = false;
    final paper = sequence(
      4,
      extract: (n) async =>
          page(n, text: n == 1 && changed ? 'Changed source text.' : null),
    );
    addTearDown(paper.close);
    await paper.start();
    await paper.indexDocument();
    final old = paper.index.snapshot;
    await paper.start(page: 2);
    await paper.start(page: 3);
    changed = true;
    expect((await paper.start())!.text, 'Changed source text.');
    expect(
      paper.index.page(1)!.passages.single.id,
      isNot(old.passages.first.id),
    );
    expect(
      paper.index.page(2)!.passages.single.id,
      old.pages[1].passages.single.id,
    );
    expect(identical(paper.index.page(4), old.pages[3]), true);
    expect(paper.index.revision, old.revision);
    expect(paper.index.snapshot.fullyResolved, true);
  });

  test('long indexing keeps playback cache bounded and leaves the cursor unchanged', () async {
    final paper = sequence(250);
    addTearDown(paper.close);
    await paper.start(page: 125);
    await paper.prepareNext();
    final watch = Stopwatch()..start();
    await paper.indexDocument();
    expect(paper.index.snapshot.processedPageCount, 250);
    expect(paper.index.snapshot.readablePassageCount, 250);
    expect(paper.cachedPageCount, 2);
    expect(paper.planner.peakExtractions, 1);
    expect(paper.planner.extractionCount, 250);
    expect(paper.pageNumber, 125);
    expect((await paper.move(1))!.text, startsWith('Page 126.'));
    // A reproducible metadata payload measure; not a Dart heap/RSS estimate.
    final payload = jsonEncode([
      for (final p in paper.index.snapshot.passages)
        [
          p.id,
          p.anchor.offset,
          p.utf16Length,
          p.scalarCount,
          p.wordCount,
          p.punctuationCount,
        ],
    ]);
    expect(utf8.encode(payload).length, lessThan(250 * 512));
    // ignore: avoid_print
    print(
      'Index fixture: 250 pages, ${watch.elapsedMilliseconds} ms, ${utf8.encode(payload).length} metadata payload bytes',
    );
  });

  test('admitted narration indexes while paused; Stop cancels and Play resumes; replacement closes it', () async {
    final entered = Completer<void>(), release = Completer<void>();
    var block = true;
    final paper = sequence(
      4,
      extract: (n) async {
        if (n == 1 && block) {
          block = false;
          entered.complete();
          await release.future;
        }
        return page(n);
      },
    );
    final first = (await paper.start(page: 3))!;
    final engine = FakeNarratorSession(), owner = Object();
    var saves = 0;
    final controller = NarrationController(
      open: (_) async => engine,
      onPosition: (_, _) => saves++,
    );
    addTearDown(controller.close);
    await controller.read(
      owner,
      () async => NarrationSource(
        documentId: owner,
        title: 'Indexed paper',
        text: first.text,
        passage: first,
        sequence: paper,
      ),
    );
    engine.playbacks.single.emit(NarrationPhase.paused);
    await entered.future;
    expect(controller.paused, true);
    expect(paper.index.snapshot.status, PaperIndexStatus.indexing);
    await controller.stop();
    release.complete();
    await flush();
    expect(paper.index.snapshot.status, PaperIndexStatus.cancelled);
    controller.togglePause();
    await flush();
    await paper.indexDocument();
    expect(paper.index.snapshot.fullyResolved, true);
    expect(paper.pageNumber, 3);
    expect(engine.playbacks, hasLength(2)); // No speech per index page.
    expect(saves, 0); // No synthesized range or bookmark generated by indexing.
    await controller.read(
      Object(),
      () async => NarrationSource(
        documentId: Object(),
        title: 'Other selection',
        text: 'Read this.',
      ),
    );
    expect(paper.index.snapshot.status, PaperIndexStatus.closed);
    expect(paper.index.retainedPageCount, 0);
  });
}
