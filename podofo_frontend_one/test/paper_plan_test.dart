import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:podofo_one/src/narration/paper_plan.dart';
import 'package:podofo_one/src/narration/source_map.dart';

PdfTextSnapshot page(List<(String, double, double)> lines) {
  final text = StringBuffer(), boxes = <PdfRect>[];
  for (final (line, x, y) in lines) {
    var position = x;
    for (final rune in line.runes) {
      final value = String.fromCharCode(rune);
      text.write(value);
      boxes.addAll(
        List.filled(value.length, PdfRect(position, y, position + 6, y - 12)),
      );
      position += 6;
    }
    text.write('\n');
    boxes.add(PdfRect(position, y, position, y - 12));
  }
  return PdfTextSnapshot(page: 1, text: text.toString(), boxes: boxes);
}

void main() {
  test('one-column reading preserves paragraphs and source anchors', () {
    final source = page([
      ('First paragraph.', 40, 700),
      ('Continued here.', 40, 682),
      ('Next paragraph.', 40, 630),
    ]);
    final plan = PaperPlanner.plan(source, 600, const PaperReadOptions());
    expect(plan.issue, isNull);
    expect(plan.passages.map((p) => p.text), [
      'First paragraph. Continued here.',
      'Next paragraph.',
    ]);
    expect(plan.passages.last.anchorAt(0)!.offset, source.text.indexOf('Next'));
  });

  test('two columns are read down the left before the right, despite interleaved PDF text', () {
    final source = page([
      for (var i = 0; i < 5; i++) ...[
        ('Left sentence $i.', 40, 700.0 - 18 * i),
        ('Right sentence $i.', 340, 700.0 - 18 * i),
      ],
    ]);
    final plan = PaperPlanner.plan(source, 600, const PaperReadOptions());
    expect(plan.description, contains('Two columns'));
    expect(plan.issue, isNull);
    expect(
      plan.passages.map((p) => p.text).join(' '),
      '${[for (var i = 0; i < 5; i++) 'Left sentence $i.'].join(' ')} ${[for (var i = 0; i < 5; i++) 'Right sentence $i.'].join(' ')}',
    );
    final right = plan.passages.firstWhere((p) => p.text.startsWith('Right'));
    expect(right.anchorAt(0)!.offset, source.text.indexOf('Right'));
  });

  test('tables and scanned pages require a choice; explicit PDF order preserves every word', () {
    final source = page([
      for (var i = 0; i < 4; i++) ...[
        ('A$i', 40, 700.0 - 18 * i),
        ('B$i', 240, 700.0 - 18 * i),
        ('C$i', 440, 700.0 - 18 * i),
      ],
    ]);
    expect(
      PaperPlanner.plan(source, 600, const PaperReadOptions()).issue,
      isNotNull,
    );
    final explicit = PaperPlanner.plan(
      source,
      600,
      const PaperReadOptions(order: PaperOrder.pdfOrder),
    );
    expect(explicit.issue, isNull);
    expect(
      explicit.passages.single.text,
      source.text.trim().replaceAll('\n', ' '),
    );
    expect(
      PaperPlanner.plan(page([]), 600, const PaperReadOptions()).issue,
      contains('OCR'),
    );
  });

  test('UTF-8 passage limits split long Unicode runs without lost or broken characters', () {
    final original = '🚀' * 7000;
    final plan = PaperPlanner.plan(
      page([(original, 40, 700)]),
      50000,
      const PaperReadOptions(),
    );
    expect(plan.passages.length, greaterThan(3));
    expect(plan.passages.map((p) => p.text).join(), original);
    for (final passage in plan.passages) {
      expect(
        utf8.encode(passage.text).length,
        lessThanOrEqualTo(PaperPlanner.maxPassageBytes),
      );
      expect(passage.text.contains('\ufffd'), false);
    }
  });

  test('reference stopping and caption exclusion are explicit options', () {
    final source = page([
      ('Body paragraph.', 40, 700),
      ('Figure 1. A result.', 40, 650),
      ('Caption continues.', 40, 632),
      ('More prose.', 40, 580),
      ('References', 40, 530),
      ('Citation one.', 40, 500),
    ]);
    final filtered = PaperPlanner.plan(
      source,
      600,
      const PaperReadOptions(skipCaptions: true),
    );
    expect(filtered.endsPaper, true);
    expect(
      filtered.passages.map((p) => p.text).join(' '),
      'Body paragraph. More prose.',
    );
    final complete = PaperPlanner.plan(
      source,
      600,
      const PaperReadOptions(stopAtReferences: false),
    );
    expect(
      complete.passages.map((p) => p.text).join(' '),
      contains('Citation one.'),
    );
  });
}
