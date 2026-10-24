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

  test('PDF sequence is retained even when geometry or script suggests another order', () {
    final source = page([('Right', 70, 700), ('Left', 40, 700)]);
    final plan = PaperPlanner.plan(source, const PaperReadOptions());
    expect(plan.issue, isNull);
    expect(plan.passages.map((p) => p.text).join(' '), 'Right Left');
    final vertical = PdfTextSnapshot(
      page: 1,
      text: 'Vertical',
      boxes: [
        for (var i = 0; i < 8; i++) PdfRect(20, 500 - i * 10, 30, 490 - i * 10),
      ],
    );
    expect(
      PaperPlanner.plan(
        vertical,
        const PaperReadOptions(),
      ).passages.single.text,
      'Vertical',
    );
    final mixed = page([('English 한국어 العربية', 40, 700)]);
    expect(
      PaperPlanner.plan(mixed, const PaperReadOptions()).passages.single.text,
      'English 한국어 العربية',
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
    final plan = PaperPlanner.plan(source, const PaperReadOptions());
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
    final plan = PaperPlanner.plan(source, const PaperReadOptions());
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
    final plan = PaperPlanner.plan(source, const PaperReadOptions());
    expect(plan.issue, isNull);
    expect(plan.passages.map((p) => p.text), [
      'First paragraph. Continued here.',
      'Next paragraph.',
    ]);
    expect(plan.passages.last.anchorAt(0)!.offset, source.text.indexOf('Next'));
  });

  test('narrow columns retain left-then-right PDF order and source anchors', () {
    // Each 16-character left line ends at x=296. The 12-point gutter is
    // smaller than the old geometric planner's 30-point split threshold.
    final source = page([
      for (var i = 0; i < 5; i++) ('Left sentence $i.', 200, 700.0 - 18 * i),
      for (var i = 0; i < 5; i++) ('Right sentence $i.', 308, 700.0 - 18 * i),
    ]);
    final plan = PaperPlanner.plan(source, const PaperReadOptions());
    expect(plan.description, 'PDF text order');
    expect(plan.issue, isNull);
    expect(
      plan.passages.map((p) => p.text).join(' '),
      '${[for (var i = 0; i < 5; i++) 'Left sentence $i.'].join(' ')} ${[for (var i = 0; i < 5; i++) 'Right sentence $i.'].join(' ')}',
    );
    final right = plan.passages.firstWhere((p) => p.text.startsWith('Right'));
    expect(right.anchorAt(0)!.offset, source.text.indexOf('Right'));
    final offsets = [
      for (final p in plan.passages)
        for (final s in p.spans) s.source.offset,
    ];
    expect(offsets, orderedEquals([...offsets]..sort()));
  });

  test(
    'tables retain their extracted sequence; textless pages still require OCR',
    () {
      final source = page([
        for (var i = 0; i < 4; i++) ...[
          ('A$i', 40, 700.0 - 18 * i),
          ('B$i', 240, 700.0 - 18 * i),
          ('C$i', 440, 700.0 - 18 * i),
        ],
      ]);
      final plan = PaperPlanner.plan(source, const PaperReadOptions());
      expect(plan.issue, isNull);
      expect(
        plan.passages.map((p) => p.text).join(' '),
        source.text.trim().replaceAll('\n', ' '),
      );
      expect(
        PaperPlanner.plan(page([]), const PaperReadOptions()).issue,
        contains('OCR'),
      );
    },
  );

  test('centered multiline caption ends before nearby body columns', () {
    final source = page([
      ('Fig. 1. A result with', 180, 740),
      ('a continued caption.', 180, 722),
      // Normal line spacing: alignment, not a large gap, ends the caption.
      ('Left body first.', 40, 704),
      ('Left body next.', 40, 686),
      ('III. Method', 308, 704),
      ('Right body first.', 308, 686),
      ('Right body next.', 308, 668),
    ]);
    final filtered = PaperPlanner.plan(
      source,
      const PaperReadOptions(skipCaptions: true),
    );
    expect(
      filtered.passages.map((p) => p.text).join(' '),
      'Left body first. Left body next. III. Method Right body first. Right body next.',
    );
    expect(
      filtered.blocks.where((b) => !b.included).single.text,
      'Fig. 1. A result with a continued caption.',
    );
    final body = filtered.passages.first;
    expect(body.anchorAt(0)!.offset, source.text.indexOf('Left body'));
    expect(body.rectangles(1, 0, 4), isNotEmpty);
  });

  test('caption ends at a font-size change even with matching left edges', () {
    final source = page([
      ('Figure 2. Caption.', 40, 700),
      ('Body in a larger font.', 40, 686),
    ]);
    final end = source.text.indexOf('\n');
    final snapshot = PdfTextSnapshot(
      page: 1,
      text: source.text,
      boxes: [
        for (var i = 0; i < source.boxes.length; i++)
          if (i < end)
            PdfRect(source.boxes[i].left, 700, source.boxes[i].right, 692)
          else
            source.boxes[i],
      ],
    );
    final plan = PaperPlanner.plan(
      snapshot,
      const PaperReadOptions(skipCaptions: true),
    );
    expect(plan.passages.single.text, 'Body in a larger font.');
  });

  test('caption labels do not exclude body sentences referring to a table or figure', () {
    final source = page([
      ('TABLE IV', 276, 740),
      ('A centered caption description.', 207, 722),
      ('Table 4 lists the results.', 40, 680),
      ('Figure 2 shows the method.', 40, 650),
      ('Fig. 3 illustrates the pipeline.', 40, 620),
      ('IV. References', 40, 580),
      ('A citation.', 40, 550),
    ]);
    final plan = PaperPlanner.plan(
      source,
      const PaperReadOptions(skipCaptions: true),
    );
    expect(
      plan.passages.map((p) => p.text).join(' '),
      'Table 4 lists the results. Figure 2 shows the method. Fig. 3 illustrates the pipeline.',
    );
    expect(plan.endsPaper, true);
    expect(
      plan.blocks.where((b) => b.kind == PaperBlockKind.caption).single.text,
      'TABLE IV A centered caption description.',
    );
  });

  test('smaller small-caps glyphs do not end a caption early', () {
    final source = page([
      ('TABLE IV', 100, 740),
      ('AN EXAMPLE OF THE', 100, 728),
      ('FORMULA', 100, 716),
      ('Body text remains.', 40, 680),
    ]);
    final lastCaption = source.text.indexOf('FORMULA');
    final bodyStart = source.text.indexOf('Body');
    final snapshot = PdfTextSnapshot(
      page: 1,
      text: source.text,
      boxes: [
        for (var i = 0; i < source.boxes.length; i++)
          if (i < bodyStart)
            PdfRect(
              source.boxes[i].left,
              source.boxes[i].top,
              source.boxes[i].right,
              source.boxes[i].top - (i < lastCaption ? 8 : 6),
            )
          else
            source.boxes[i],
      ],
    );
    final plan = PaperPlanner.plan(
      snapshot,
      const PaperReadOptions(skipCaptions: true),
    );
    expect(plan.passages.single.text, 'Body text remains.');
    expect(
      plan.blocks.where((b) => b.kind == PaperBlockKind.caption).single.text,
      'TABLE IV AN EXAMPLE OF THE FORMULA',
    );
  });

  test(
    'blank source lines separate paragraphs even without a geometric gap',
    () {
      final source = page([
        ('First paragraph.', 40, 700),
        ('', 40, 688),
        ('Next paragraph.', 40, 682),
      ]);
      final plan = PaperPlanner.plan(source, const PaperReadOptions());
      expect(plan.passages.map((p) => p.text), [
        'First paragraph.',
        'Next paragraph.',
      ]);
    },
  );

  test('UTF-8 passage limits split long Unicode runs without lost or broken characters', () {
    final original = '🚀' * 7000;
    final plan = PaperPlanner.plan(
      page([(original, 40, 700)]),
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
      const PaperReadOptions(skipCaptions: true),
    );
    expect(filtered.endsPaper, true);
    expect(
      filtered.passages.map((p) => p.text).join(' '),
      'Body paragraph. More prose.',
    );
    final complete = PaperPlanner.plan(
      source,
      const PaperReadOptions(stopAtReferences: false),
    );
    expect(
      complete.passages.map((p) => p.text).join(' '),
      contains('Citation one.'),
    );
  });
}
