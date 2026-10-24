import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:podofo_one/src/narration/narration_controller.dart';
import 'package:podofo_one/src/narration/paper_plan.dart';
import 'package:podofo_one/src/narration/paper_sequence.dart';
import 'package:podofo_one/src/narration/pdf_text_repository.dart';
import 'package:podofo_one/src/narration/source_map.dart';
import 'package:podofo_one/src/services/pdf_session.dart';

import 'fixtures/narration_pdf_fixture.dart';
import 'support/fake_narrator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('podofo-hyphen-');
    await pdfrxInitialize(tmpPath: directory.path);
  });
  tearDownAll(() async {
    await PdfrxEntryFunctions.instance.stopBackgroundWorker();
    await directory.delete(recursive: true);
  });

  test(
    'PDFium line-end marker joins narration without changing PDF source',
    () async {
      final artifact = File('build/test-artifacts/discretionary-hyphen.pdf');
      await artifact.parent.create(recursive: true);
      await artifact.writeAsBytes(discretionaryHyphenPdfFixture());
      final session = await PdfSession.open(artifact.path);
      try {
        expect(
          PdfrxEntryFunctions.instance.backendType,
          PdfrxBackendType.pdfium,
        );
        final raw = (await session.lease.document.pages.first.loadText())!;
        expect(raw.fullText, contains('inter\u0002national'));
        expect(raw.fullText, contains('well-known'));
        expect(raw.fullText, isNot(contains('\ufffe')));

        // Capture the actual visible hyphen as well as testing extracted text.
        final rendered = (await session.lease.document.pages.first.render())!;
        final image = await rendered.createImage();
        final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        await File('build/test-artifacts/discretionary-hyphen.png')
            .writeAsBytes(png.buffer.asUint8List());
        image.dispose();
        rendered.dispose();

        final page = (await PdfTextRepository(session).extract(1)).text;
        final selectionText = await session.lease.document.pages.first
            .loadStructuredText();
        expect(page.text, raw.fullText);
        expect(page.text, selectionText.fullText);
        expect(page.boxes, selectionText.charRects);
        final selected = NarrationPassage.fromSlices([
          PdfTextSlice(
            PdfTextSnapshot.fromText(selectionText),
            0,
            page.text.length,
          ),
        ]);
        const expected =
            'We study international cooperation with well-known methods.';
        expect(selected.text, expected);
        final plan = PaperPlanner.plan(
          page,
          const PaperReadOptions(skipRunningMatter: false),
        );
        expect(plan.passages.single.text, expected);
        final marker = page.text.indexOf('\u0002');
        final wordStart = expected.indexOf('international');
        final wordEnd = wordStart + 'international'.length;
        for (final passage in [selected, plan.passages.single]) {
          expect(passage.anchorAt(marker)!.offset, marker + 1);
          expect(passage.offsetOf(page.anchor(marker)), marker);
          expect(passage.offsetOf(page.anchor(marker + 1)), marker);
          expect(
            passage.sliceFrom(marker).text,
            'national cooperation with well-known methods.',
          );
          final rects = passage.rectangles(1, wordStart, wordEnd);
          expect(rects, hasLength(2)); // Both printed lines of the joined word.
          expect(
            rects.first,
            page.boxes.sublist(wordStart, marker).boundingRect(),
          );
          expect(
            rects.last,
            page.boxes.sublist(marker + 1, wordEnd + 1).boundingRect(),
          );
          expect(passage.rectangles(1, marker, marker + 1), [
            page.boxes[marker + 1],
          ]);
        }

        final sequence = PaperSequence(
          session,
          const PaperReadOptions(skipRunningMatter: false),
        );
        final engine = FakeNarratorSession();
        final controller = NarrationController(open: (_) async => engine);
        try {
          final passage = (await sequence.start())!;
          await controller.read(
            session,
            () async => NarrationSource(
              documentId: session,
              title: 'Discretionary hyphen',
              text: passage.text,
              passage: passage,
            ),
          );
          expect(engine.texts.single, expected);
          final resumed = (await sequence.start(anchor: page.anchor(marker)))!;
          expect(resumed.text, 'national cooperation with well-known methods.');
          expect(resumed.anchorAt(0)!.offset, marker + 1);
        } finally {
          await controller.close();
          sequence.close();
        }
        // Normalizing narration never writes back to extraction/selection.
        expect(await session.lease.document.pages.first.loadText(), raw);
        expect(selectionText.fullText, raw.fullText);
        expect(selectionText.charRects, page.boxes);
      } finally {
        await session.close();
      }
    },
  );
}
