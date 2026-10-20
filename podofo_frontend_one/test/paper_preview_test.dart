import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:podofo_one/src/narration/paper_plan.dart';
import 'package:podofo_one/src/narration/paper_sequence.dart';
import 'package:podofo_one/src/services/pdf_session.dart';
import 'package:podofo_one/src/widgets/components/paper_reading_preview.dart';

import 'fixtures/narration_pdf_fixture.dart';

Future<void> wait(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 150; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 20));
    if (ready()) return;
  }
  fail('Preview did not reach the expected state.');
}

void main() {
  testWidgets(
    'preview explains scanned pages and requires a readable page before playback',
    (tester) async {
      final directory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('podofo-preview-'),
      ))!;
      await tester.runAsync(() => pdfrxInitialize(tmpPath: directory.path));
      final file = File('${directory.path}/preview.pdf')
        ..writeAsBytesSync(
          narrationPdfFixture([
            '',
            'BT /F1 18 Tf 60 700 Td (A readable paper.) Tj ET\n',
          ]),
        );
      final session = (await tester.runAsync(
        () => PdfSession.open(file.path),
      ))!;
      final sequence = PaperSequence(session, const PaperReadOptions());
      PaperReadingChoice? choice;
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    choice = await showDialog<PaperReadingChoice>(
                      context: context,
                      builder: (_) =>
                          PaperReadingPreview(sequence: sequence, page: 1),
                    );
                  },
                  child: const Text('Listen'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Listen'));
        await wait(
          tester,
          () => find.textContaining('OCR').evaluate().isNotEmpty,
        );
        expect(
          tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
          isNull,
        );
        await tester.tap(find.byTooltip('Next preview page'));
        await wait(
          tester,
          () => find.text('A readable paper.').evaluate().isNotEmpty,
        );
        await tester.tap(find.text('Read from this page'));
        await tester.pumpAndSettle();
        expect(choice!.page, 2);
        expect(choice!.options.order, PaperOrder.automatic);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        sequence.close();
        await tester.runAsync(() async {
          await session.close();
          await PdfrxEntryFunctions.instance.stopBackgroundWorker();
          await directory.delete(recursive: true);
        });
      }
    },
  );
}
