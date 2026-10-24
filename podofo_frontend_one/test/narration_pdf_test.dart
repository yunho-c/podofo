import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:podofo_one/src/narration/narration_controller.dart';
import 'package:podofo_one/src/narration/narration_painter.dart';
import 'package:podofo_one/src/narration/narrator.dart';
import 'package:podofo_one/src/narration/paper_sequence.dart';
import 'package:podofo_one/src/narration/paper_plan.dart';
import 'package:podofo_one/src/narration/source_map.dart';
import 'package:podofo_one/src/services/pdf_session.dart';
import 'package:podofo_one/src/services/pdf_highlights.dart';

import 'fixtures/pdf_fixture.dart';
import 'fixtures/narration_pdf_fixture.dart';
import 'support/fake_narrator.dart';
import 'document_seek_test.dart' as seek;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('podofo-narration-pdf-');
    await pdfrxInitialize(tmpPath: directory.path);
  });
  tearDownAll(() async {
    await PdfrxEntryFunctions.instance.stopBackgroundWorker();
    await directory.delete(recursive: true);
  });
  test(
    'real PDF Unicode extraction expands geometry before formatting',
    () async {
      final file = File('${directory.path}/unicode.pdf')
        ..writeAsBytesSync(
          narrationPdfFixture([
            'BT /F1 18 Tf 60 700 Td (ABC) Tj ET\n',
          ], unicodeMap: narrationUnicodeMap),
        );
      final session = await PdfSession.open(file.path);
      try {
        final snapshot = await session.readLocked(
          (pdf) async => PdfTextSnapshot.fromText(
            await NarrationPdfPage(pdf.pages.first).loadStructuredText(),
          ),
        );
        // PDFium expands this font's ligature before exposing its Unicode text.
        expect(snapshot.text.trim(), '🚀fié');
        final passage = NarrationPassage.fromSlices([
          PdfTextSlice(snapshot, 0, snapshot.text.length),
        ]);
        expect(passage.text, '🚀fié');
        expect(passage.anchorAt(2)!.offset, 2);
        expect(passage.anchorAt(3)!.offset, 3);
        expect(snapshot.boxes[0], snapshot.boxes[1]);
        expect(passage.rectangles(1, 0, 2), hasLength(1));
      } finally {
        await session.close();
      }
    },
  );

  test('scrub paint replaces playback and skips unavailable or other-document geometry', () async {
    final file = File('${directory.path}/scrub.pdf')
      ..writeAsBytesSync(pdfFixture());
    final session = await PdfSession.open(file.path);
    final paper = PaperSequence(
      session,
      const PaperReadOptions(skipRunningMatter: false),
    );
    final engine = seek.SeekSession();
    final narration = await seek.reader(paper, engine);
    try {
      Future<bool> painted(int number, {Object? owner}) async {
        final page = session.lease.document.pages[number - 1];
        final recorder = ui.PictureRecorder();
        // A transparent backing makes any painted glyph rectangle observable.
        final targetCanvas = ui.Canvas(recorder);
        paintNarration(
          targetCanvas,
          ui.Rect.fromLTWH(0, 0, page.width, page.height),
          page,
          narration,
          owner ?? paper,
        );
        final picture = recorder.endRecording();
        final image = await picture.toImage(
          page.width.ceil(),
          page.height.ceil(),
        );
        final data = (await image.toByteData())!.buffer.asUint8List();
        var found = false;
        for (var i = 3; i < data.length; i += 4) {
          if (data[i] != 0) {
            found = true;
            break;
          }
        }
        image.dispose();
        picture.dispose();
        return found;
      }

      expect(await painted(1), true);
      // Page 2 is prefetched with rotated geometry; its preview replaces page 1.
      narration.previewDocumentSeek(paper.timeline.targetAt(15000000));
      expect(narration.previewHighlight, isNotNull);
      expect(await painted(1), false);
      expect(await painted(2), true);
      expect(await painted(2, owner: Object()), false);
      final extractions = paper.planner.extractionCount;
      narration.previewDocumentSeek(paper.timeline.targetAt(25000000));
      expect(narration.previewHighlight, isNull);
      expect(await painted(1), false);
      expect(await painted(3), false);
      expect(paper.planner.extractionCount, extractions);
      narration.clearDocumentPreview();
      expect(await painted(1), true);
      await narration.stop();
      narration.previewDocumentSeek(paper.timeline.targetAt(5000000));
      expect(await painted(1), true); // Preview also works while stopped.
      await narration.dismiss();
      expect(await painted(1), false);
    } finally {
      await narration.close();
      await session.close();
    }
  });

  test('listening paint uses cropped/rotated transforms without annotations; save preserves anchors', () async {
    final file = File('${directory.path}/geometry.pdf')
      ..writeAsBytesSync(pdfFixture());
    final session = await PdfSession.open(file.path);
    final engine = FakeNarratorSession();
    final narration = NarrationController(open: (_) async => engine);
    try {
      final snapshots = await session.readLocked(
        (pdf) async => [
          for (final page in pdf.pages)
            PdfTextSnapshot.fromText(
              await NarrationPdfPage(page).loadStructuredText(),
            ),
        ],
      );
      for (var i = 0; i < snapshots.length; i++) {
        final snapshot = snapshots[i];
        final passage = NarrationPassage.fromSlices([
          PdfTextSlice(snapshot, 0, snapshot.text.length),
        ]);
        await narration.read(
          session,
          () async => NarrationSource(
            documentId: session,
            title: 'Geometry',
            text: passage.text,
            passage: passage,
          ),
        );
        engine.playbacks.last.events.add(
          NarrationSnapshot(
            phase: NarrationPhase.playing,
            start: 0,
            end: passage.text.length,
          ),
        );
        final page = session.lease.document.pages[i];
        final pageRect = ui.Rect.fromLTWH(
          0,
          0,
          page.width * 2,
          page.height * 2,
        );
        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder)
          ..drawColor(const ui.Color(0xffffffff), ui.BlendMode.src);
        paintNarration(canvas, pageRect, page, narration, session);
        final picture = recorder.endRecording();
        final image = await picture.toImage(
          pageRect.width.ceil(),
          pageRect.height.ceil(),
        );
        final rgba = (await image.toByteData())!.buffer.asUint8List();
        final rectangle = passage
            .rectangles(i + 1, 0, passage.text.length)
            .first
            .toRect(page: page, scaledPageSize: pageRect.size);
        final pixel =
            (rectangle.center.dy.floor() * image.width +
                rectangle.center.dx.floor()) *
            4;
        expect(
          rgba[pixel + 2],
          lessThan(255),
          reason: 'page ${i + 1} must paint over its transformed glyph',
        );
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        final artifact = File(
          'build/test-artifacts/narration-page-${i + 1}.png',
        );
        await artifact.parent.create(recursive: true);
        await artifact.writeAsBytes(png!.buffer.asUint8List());
        image.dispose();
        picture.dispose();
        expect(
          await PdfHighlights.listPage(session.lease.document, i + 1),
          isEmpty,
        );
      }
      expect(session.revision, 0);
      await session.highlight([
        HighlightRegion(1, [snapshots.first.boxes.first]),
      ], 0x66ffcc00);
      await session.save();
      final after = await session.readLocked(
        (pdf) async => PdfTextSnapshot.fromText(
          await NarrationPdfPage(pdf.pages.first).loadStructuredText(),
        ),
      );
      expect(after.textHash, snapshots.first.textHash);
      expect(narration.active, true);
    } finally {
      await narration.close();
      await session.close(discard: true);
    }
  });

  test(
    'close waits for an in-flight snapshot; returned text needs no live PDF',
    () async {
      final file = File('${directory.path}/closing.pdf')
        ..writeAsBytesSync(pdfFixture());
      final session = await PdfSession.open(file.path);
      final entered = Completer<void>(), release = Completer<void>();
      final snapshot = session.readLocked((pdf) async {
        entered.complete();
        await release.future;
        return PdfTextSnapshot.fromText(
          await NarrationPdfPage(pdf.pages.first).loadStructuredText(),
        );
      });
      await entered.future;
      var closed = false;
      final close = session.close().then((_) {
        closed = true;
      });
      await Future<void>.delayed(Duration.zero);
      expect(closed, false);
      release.complete();
      final detached = await snapshot;
      await close;
      expect(session.lease.isClosed, true);
      expect(
        NarrationPassage.fromSlices([
          PdfTextSlice(detached, 0, detached.text.length),
        ]).text,
        'Hello highlight',
      );
    },
  );
}
