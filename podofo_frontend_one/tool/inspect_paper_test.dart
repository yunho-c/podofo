// Run explicitly with tool/test_macos.py; never downloads or changes the input.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:podofo_one/src/narration/paper_plan.dart';
import 'package:podofo_one/src/narration/paper_sequence.dart';
import 'package:podofo_one/src/services/pdf_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'inspect a local paper and retain source-page/reading-order evidence',
    () async {
      final input = Platform.environment['PODOFO_PDF'];
      final output = Platform.environment['PODOFO_PAPER_OUTPUT'];
      if (input == null || output == null) {
        fail(
          'Set PODOFO_PDF and PODOFO_PAPER_OUTPUT to the input PDF and a new evidence directory.',
        );
      }
      final pages = (Platform.environment['PODOFO_PAGES'] ?? '1')
          .split(',')
          .map(int.parse)
          .toList();
      final orders = (Platform.environment['PODOFO_ORDERS'] ?? 'automatic')
          .split(',')
          .map((name) => PaperOrder.values.byName(name))
          .toList();
      final destination = Directory(output);
      if (await destination.exists()) {
        fail('Evidence directory already exists: $output');
      }
      await destination.create(recursive: true);
      final temporary = await Directory.systemTemp.createTemp(
        'podofo-paper-review-',
      );
      Pdfrx.pdfiumModulePath = Platform.environment['PDFIUM_PATH'];
      await pdfrxInitialize(tmpPath: temporary.path);
      final session = await PdfSession.open(input);
      final sequence = PaperSequence(session, const PaperReadOptions());
      final receipt = <Object?>[];
      try {
        for (final number in pages) {
          final page = session.lease.document.pages[number - 1];
          final rendered = (await page.render(
            fullWidth: page.width * 1.5,
            fullHeight: page.height * 1.5,
          ))!;
          final image = await rendered.createImage();
          try {
            final png = await image.toByteData(format: ui.ImageByteFormat.png);
            await File('$output/page-$number.png')
                .writeAsBytes(png!.buffer.asUint8List());
          } finally {
            image.dispose();
            rendered.dispose();
          }
          for (final order in orders) {
            final plan = await sequence.preview(
              number,
              preferences: PaperReadOptions(order: order),
            );
            if (order == orders.first) {
              await File('$output/source-$number.json').writeAsString(
                jsonEncode({
                  'text': plan.page.text,
                  'boxes': [
                    for (final r in plan.page.boxes)
                      [r.left, r.top, r.right, r.bottom],
                  ],
                }),
              );
            }
            receipt.add({
              'page': number,
              'order': order.name,
              'description': plan.description,
              'issue': plan.issue,
              'text_hash': plan.page.textHash,
              'ends_paper': plan.endsPaper,
              'excluded': [
                for (final block in plan.blocks.where((b) => !b.included))
                  {'kind': block.kind.name, 'text': block.text},
              ],
              'passages': [
                for (final passage in plan.passages)
                  {
                    'text': passage.text,
                    'bytes': utf8.encode(passage.text).length,
                    'source_start': passage.anchorAt(0)?.offset,
                    'source_end': passage.spans.lastOrNull?.sourceEnd,
                  },
              ],
            });
            expect(
              plan.passages.every(
                (p) =>
                    utf8.encode(p.text).length <= PaperPlanner.maxPassageBytes,
              ),
              true,
            );
          }
        }
        await File('$output/reading-order.json')
            .writeAsString(const JsonEncoder.withIndent('  ').convert(receipt));
      } finally {
        sequence.close();
        await session.close();
        await PdfrxEntryFunctions.instance.stopBackgroundWorker();
        await temporary.delete(recursive: true);
      }
    },
  );
}
