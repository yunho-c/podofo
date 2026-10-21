import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:podofo_one/src/narration/paper_plan.dart';
import 'package:podofo_one/src/narration/pdf_text_repository.dart';
import 'package:podofo_one/src/narration/running_matter.dart';
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
  test(
    'pagination advances across pages; repeated numeric chart labels do not',
    () {
      List<MarginLine> margins(int number, String label) {
        final text = page([(label, 295, 70)]);
        return marginLines(
          ExtractedPaperPage(
            PdfTextSnapshot(page: number, text: text.text, boxes: text.boxes),
            612,
            792,
          ),
        );
      }

      expect(margins(3, '3').single.matches(margins(4, '4').single), true);
      expect(margins(3, '100').single.matches(margins(4, '100').single), false);
    },
  );

  test('vertical marginal text needs review; geometric order tolerates reverse PDF emission', () {
    final source = page([('Right', 70, 700), ('Left', 40, 700)]);
    expect(
      PaperPlanner.plan(
        source,
        600,
        const PaperReadOptions(),
      ).passages.single.text,
      'Left Right',
    );
    final vertical = PdfTextSnapshot(
      page: 1,
      text: 'Vertical',
      boxes: [
        for (var i = 0; i < 8; i++) PdfRect(20, 500 - i * 10, 30, 490 - i * 10),
      ],
    );
    expect(
      PaperPlanner.plan(vertical, 600, const PaperReadOptions()).issue,
      contains('vertical'),
    );
    expect(
      PaperPlanner.plan(
        vertical,
        600,
        const PaperReadOptions(order: PaperOrder.pdfOrder),
      ).passages.single.text,
      'Vertical',
    );
  });

  test('PDFium joined words are ordered at their first visual line', () {
    final visual = page([
      ('Brief methods repre\u0002', 40, 700),
      ('sent a result. We represent data.', 40, 682),
    ]);
    final wrap = visual.text.indexOf('\n');
    final source = PdfTextSnapshot(
      page: 1,
      text: visual.text.replaceRange(wrap, wrap + 1, ''),
      boxes: [...visual.boxes.take(wrap), ...visual.boxes.skip(wrap + 1)],
    );
    final plan = PaperPlanner.plan(source, 600, const PaperReadOptions());
    expect(plan.issue, isNull);
    final passage = plan.passages.single;
    expect(
      passage.text,
      'Brief methods represent a result. We represent data.',
    );
    final start = passage.text.indexOf('represent');
    expect(passage.rectangles(1, start, start + 9), hasLength(2));
    expect(passage.anchorAt(start + 5)!.offset, source.text.indexOf('sent'));
  });

  test('line-end joining preserves compounds and maps both source lines', () {
    final source = page([
      ('We study inter-', 40, 700),
      ('national data and a well-', 40, 682),
      ('being scale. International data agree.', 40, 664),
      ('Eq. (1), Fig. 2 and 3.14 remain literal.', 40, 610),
    ]);
    final plan = PaperPlanner.plan(source, 600, const PaperReadOptions());
    final passage = plan.passages.first;
    expect(
      passage.text,
      'We study international data and a well-being scale. International data agree.',
    );
    final start = passage.text.indexOf('international');
    expect(
      passage.rectangles(1, start, start + 'international'.length),
      hasLength(2),
    );
    expect(
      passage.anchorAt(start + 5)!.offset,
      source.text.indexOf('national'),
    );
    expect(plan.passages.last.text, 'Eq. (1), Fig. 2 and 3.14 remain literal.');
    final soft = PaperPlanner.plan(
      page([('A discre\u00ad', 40, 700), ('tionary break.', 40, 682)]),
      600,
      const PaperReadOptions(),
    );
    expect(soft.passages.single.text, 'A discretionary break.');
  });

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
    final mixed = page([('English 한국어 العربية', 40, 700)]);
    expect(
      PaperPlanner.plan(mixed, 600, const PaperReadOptions()).issue,
      isNotNull,
    );
    expect(
      PaperPlanner.plan(
        mixed,
        600,
        const PaperReadOptions(order: PaperOrder.pdfOrder),
      ).passages.single.text,
      'English 한국어 العربية',
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
