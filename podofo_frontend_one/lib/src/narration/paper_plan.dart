import 'dart:convert';
import 'dart:math' as math;

import 'package:pdfrx/pdfrx.dart';

import 'source_map.dart';
import 'running_matter.dart';

enum PaperOrder { automatic, singleColumn, twoColumns, pdfOrder }

class PaperReadOptions {
  const PaperReadOptions({
    this.order = PaperOrder.automatic,
    this.stopAtReferences = true,
    this.skipCaptions = false,
    this.skipRunningMatter = true,
  });
  final PaperOrder order;
  final bool stopAtReferences, skipCaptions, skipRunningMatter;

  /// Value identity for shared page work and compact passage descriptors.
  String get key =>
      '${PaperPlanner.version}:${order.name}:$stopAtReferences:$skipCaptions:$skipRunningMatter';
}

enum PaperBlockKind { paragraph, heading, caption, references, runningMatter }

class PaperReadingBlock {
  PaperReadingBlock(
    this.kind,
    Iterable<PdfTextSlice> slices, {
    this.included = true,
  }) : slices = List.unmodifiable(slices);
  final PaperBlockKind kind;
  final List<PdfTextSlice> slices;
  final bool included;
  String get text => NarrationPassage.fromSlices(slices).text;
}

class PaperPagePlan {
  PaperPagePlan({
    required this.page,
    required this.passages,
    required this.description,
    this.issue,
    this.endsPaper = false,
    this.blocks = const [],
  });
  final PdfTextSnapshot page;
  final List<NarrationPassage> passages;
  final String description;
  final String? issue;
  final bool endsPaper;
  final List<PaperReadingBlock> blocks;
}

class _Word {
  _Word(this.start, this.end, this.bounds, {this.joinPrevious = false});
  final int start, end;
  final PdfRect bounds;
  final bool joinPrevious;
}

class _Line {
  _Line(this.words, this.column);
  final List<_Word> words;
  final int column;
  PdfRect get bounds => words.map((w) => w.bounds).toList().boundingRect();
  String text(PdfTextSnapshot page) =>
      words.map((w) => page.text.substring(w.start, w.end)).join(' ');
}

/// Conservative geometric ordering. Unsupported layouts remain explicit.
abstract final class PaperPlanner {
  static const version = 2;
  static const maxPageUnits = 200000;
  static const maxPassageBytes = 4096;

  static PaperPagePlan plan(
    PdfTextSnapshot page,
    double width,
    PaperReadOptions options, {
    List<MarginLine> runningMatter = const [],
  }) {
    PaperPagePlan issue(String reason) => PaperPagePlan(
      page: page,
      passages: const [],
      description: 'Review page ${page.page}',
      issue: reason,
    );
    if (page.text.trim().isEmpty) {
      return issue('Page ${page.page} has no readable text. It may need OCR.');
    }
    if (page.text.length > maxPageUnits) {
      return issue(
        'Page ${page.page} contains too much text for automatic reading. Select a smaller passage.',
      );
    }
    final words = <_Word>[];
    bool usable(PdfRect r) =>
        r.width > 0 &&
        r.height > 0 &&
        [r.left, r.right, r.top, r.bottom].every((v) => v.isFinite);
    for (final match in RegExp(r'\S+', unicode: true).allMatches(page.text)) {
      if (options.skipRunningMatter &&
          runningMatter.any(
            (line) => match.start >= line.start && match.end <= line.end,
          )) {
        continue;
      }
      final boxes = page.boxes
          .sublist(match.start, match.end)
          .where(usable)
          .toList();
      if (boxes.isEmpty) continue;
      final whole = boxes.boundingRect();
      if (options.order == PaperOrder.automatic &&
          match.end - match.start >= 3 &&
          whole.height > boxes.first.height * 2.5 &&
          whole.width < whole.height * .75) {
        return issue(
          'Page ${page.page} contains vertical or overlapping text. Review its PDF order or select the body text.',
        );
      }
      // PDFium can join a wrapped word with U+0002 and no newline. Split its
      // geometry into visual runs before ordering, then join the spoken slices
      // again. A page-wide bounding rectangle would scramble both rows.
      var begin = match.start;
      var run = <PdfRect>[];
      void appendRun(int end) {
        if (run.isNotEmpty) {
          words.add(
            _Word(
              begin,
              end,
              run.boundingRect(),
              joinPrevious: begin != match.start,
            ),
          );
        }
      }

      for (var at = match.start; at < match.end; at++) {
        final rect = page.boxes[at];
        if (!usable(rect)) continue;
        if (run.isNotEmpty &&
            rect.left < run.last.left &&
            (rect.top <= run.first.bottom || rect.bottom >= run.first.top)) {
          appendRun(at);
          begin = at;
          run = [];
        }
        run.add(rect);
      }
      appendRun(match.end);
    }
    if (words.isEmpty) {
      return issue(
        runningMatter.isEmpty
            ? 'Page ${page.page} has no usable text positions.'
            : 'Page ${page.page} has no body text after excluding headers and footers. Include them or skip this page.',
      );
    }
    final heights = words.map((w) => w.bounds.height).toList()..sort();
    final height = heights[heights.length ~/ 2];
    final rows = <List<_Word>>[];
    for (final word in [
      ...words,
    ]..sort((a, b) => b.bounds.top.compareTo(a.bounds.top))) {
      final row = rows.lastOrNull;
      if (row == null ||
          (row.first.bounds.center.y - word.bounds.center.y).abs() >
              height * .55) {
        rows.add([word]);
      } else {
        row.add(word);
      }
    }
    final lines = <_Line>[], gutters = <double>[];
    var complexRows = 0;
    for (final row in rows) {
      row.sort((a, b) => a.bounds.left.compareTo(b.bounds.left));
      final runs = <List<_Word>>[[]];
      for (final word in row) {
        final previous = runs.last.lastOrNull;
        if (previous != null &&
            word.bounds.left - previous.bounds.right >
                math.max(18, height * 2.5)) {
          if (previous.bounds.right < width * .7 &&
              word.bounds.left > width * .3) {
            gutters.add((previous.bounds.right + word.bounds.left) / 2);
          }
          runs.add([]);
        }
        runs.last.add(word);
      }
      if (runs.length > 2) complexRows++;
      lines.addAll(runs.map((run) => _Line(run, 0)));
    }
    if (options.order == PaperOrder.automatic &&
        (complexRows >= 2 || RegExp(r'[\u0590-\u08ff]').hasMatch(page.text))) {
      return issue(
        'Page ${page.page} needs a reading-order choice. Use PDF order or select the text to read.',
      );
    }
    gutters.sort();
    final split = gutters.isEmpty ? width / 2 : gutters[gutters.length ~/ 2];
    final left = lines.where((l) => l.bounds.right <= split).length;
    final right = lines.where((l) => l.bounds.left >= split).length;
    final two =
        options.order == PaperOrder.twoColumns ||
        (options.order == PaperOrder.automatic &&
            gutters.length >= 3 &&
            left >= 3 &&
            right >= 3);
    if (two &&
        options.order == PaperOrder.automatic &&
        lines.where((line) => line.words.length >= 3).length <
            lines.length * .6) {
      return issue(
        'Page ${page.page} may contain a table or equations. Review its reading order.',
      );
    }
    List<_Line> ordered;
    if (options.order == PaperOrder.pdfOrder) {
      // The producer's sequence is an explicit escape hatch, never called inferred order.
      ordered = [];
      var sourceLine = <_Word>[];
      for (final word in words) {
        if (sourceLine.isNotEmpty &&
            page.text
                .substring(sourceLine.last.end, word.start)
                .contains('\n')) {
          ordered.add(_Line(sourceLine, 0));
          sourceLine = [];
        }
        sourceLine.add(word);
      }
      if (sourceLine.isNotEmpty) ordered.add(_Line(sourceLine, 0));
    } else if (two) {
      final spanning =
          lines
              .where((l) => l.bounds.left < split && l.bounds.right > split)
              .toList()
            ..sort((a, b) => b.bounds.top.compareTo(a.bounds.top));
      if (spanning.length > 64) {
        return issue(
          'Page ${page.page} mixes too many layout regions. Review its PDF order.',
        );
      }
      ordered = [];
      var top = double.infinity;
      for (final divider in [...spanning, null]) {
        final bottom = divider?.bounds.top ?? double.negativeInfinity;
        for (var column = 0; column < 2; column++) {
          final band =
              lines
                  .where(
                    (l) =>
                        !spanning.contains(l) &&
                        l.bounds.top <= top &&
                        l.bounds.top > bottom &&
                        (column == 0
                            ? l.bounds.right <= split
                            : l.bounds.left >= split),
                  )
                  .toList()
                ..sort((a, b) => b.bounds.top.compareTo(a.bounds.top));
          ordered.addAll(band.map((line) => _Line(line.words, column)));
        }
        if (divider != null) {
          ordered.add(divider);
          top = divider.bounds.top;
        }
      }
    } else {
      ordered = lines; // Rows already run top-to-bottom and left-to-right.
    }
    if (ordered.fold<int>(0, (n, l) => n + l.words.length) != words.length) {
      return issue(
        'Page ${page.page} has overlapping columns. Review its PDF order.',
      );
    }

    final paragraphs = <List<_Word>>[];
    final blocks = <PaperReadingBlock>[
      if (options.skipRunningMatter)
        for (final line in runningMatter)
          PaperReadingBlock(PaperBlockKind.runningMatter, [
            PdfTextSlice(page, line.start, line.end),
          ], included: false),
    ];
    var current = <_Word>[];
    _Line? previous;
    var endsPaper = false;
    final caption = RegExp(
      r'^(?:fig(?:ure)?\.?|table)\s+\d',
      caseSensitive: false,
    );
    final heading = RegExp(
      r'^(?:\d+(?:\.\d+)*[.\s]+)?(?:abstract|introduction|background|methods?|materials and methods|results?|discussion|conclusions?|acknowledg(?:e)?ments?)\s*$',
      caseSensitive: false,
    );
    final references = RegExp(
      r'^(?:\d+[.\s]+)?(?:references|bibliography)\s*$',
      caseSensitive: false,
    );
    for (final line in ordered) {
      final text = line.text(page);
      final originalLine = options.order != PaperOrder.pdfOrder
          ? text
          : page.text
                .substring(
                  page.text.lastIndexOf(
                        '\n',
                        math.max(0, line.words.first.start - 1),
                      ) +
                      1,
                  page.text.indexOf('\n', line.words.last.end) < 0
                      ? page.text.length
                      : page.text.indexOf('\n', line.words.last.end),
                )
                .trim();
      if (options.stopAtReferences &&
          references.hasMatch(
            options.order == PaperOrder.pdfOrder ? originalLine : text,
          )) {
        endsPaper = true;
        blocks.add(
          PaperReadingBlock(PaperBlockKind.references, [
            for (final word in line.words)
              PdfTextSlice(page, word.start, word.end),
          ], included: false),
        );
        break;
      }
      final newParagraph =
          previous != null &&
          (caption.hasMatch(text) ||
              heading.hasMatch(text) ||
              heading.hasMatch(previous.text(page)) ||
              references.hasMatch(text) ||
              references.hasMatch(previous.text(page)) ||
              (options.order != PaperOrder.pdfOrder &&
                  (previous.column != line.column ||
                      previous.bounds.bottom - line.bounds.top > height * .75 ||
                      line.bounds.left - previous.bounds.left > height * 1.2 ||
                      line.bounds.height > height * 1.4)));
      if (newParagraph && current.isNotEmpty) {
        paragraphs.add(current);
        current = [];
      }
      current.addAll(line.words);
      previous = line;
    }
    if (current.isNotEmpty) paragraphs.add(current);
    final passages = <NarrationPassage>[];
    for (final paragraph in paragraphs) {
      final literal = paragraph
          .map((word) => page.text.substring(word.start, word.end))
          .join(' ');
      final isCaption = caption.hasMatch(literal);
      final joined = <int>{
            for (var i = 1; i < paragraph.length; i++)
              if (paragraph[i].joinPrevious &&
                  paragraph[i - 1].end == paragraph[i].start)
                paragraph[i].start,
          },
          shortened = <int>{};
      for (var i = 1; i < paragraph.length; i++) {
        final before = paragraph[i - 1], after = paragraph[i];
        final leftText = page.text.substring(before.start, before.end);
        final rightText = page.text.substring(after.start, after.end);
        final wraps =
            before.bounds.bottom > after.bounds.top ||
            (before.end <= after.start &&
                page.text.substring(before.end, after.start).contains('\n'));
        if (!wraps) continue;
        final rightWord = RegExp(r'^([a-z]{2,})[.,;:!?)]*$')
            .firstMatch(rightText);
        final discretionary = leftText.endsWith('\u00ad');
        final verified =
            RegExp(r'^[A-Za-z]{2,}-$').hasMatch(leftText) &&
            rightWord != null &&
            page.intactWords.contains(
              '${leftText.substring(0, leftText.length - 1)}${rightWord[1]}'
                  .toLowerCase(),
            );
        if (discretionary ||
            (RegExp(r'^[A-Za-z]{2,}-$').hasMatch(leftText) &&
                rightWord != null)) {
          if (discretionary || verified) shortened.add(before.start);
          joined.add(after.start);
        }
      }
      final block = PaperReadingBlock(
        isCaption
            ? PaperBlockKind.caption
            : references.hasMatch(literal)
            ? PaperBlockKind.references
            : heading.hasMatch(literal)
            ? PaperBlockKind.heading
            : PaperBlockKind.paragraph,
        [
          for (final word in paragraph)
            PdfTextSlice(
              page,
              word.start,
              word.end - (shortened.contains(word.start) ? 1 : 0),
              joinPrevious: joined.contains(word.start),
            ),
        ],
        included: !options.skipCaptions || !isCaption,
      );
      blocks.add(block);
      if (!block.included) continue;
      final slices = <PdfTextSlice>[];
      var bytes = 0;
      for (final word in paragraph) {
        // Split even pathological no-whitespace runs on Unicode scalar boundaries.
        var begin = word.start, end = begin;
        final wordEnd = word.end - (shortened.contains(word.start) ? 1 : 0);
        void appendSlice() {
          if (end > begin) {
            slices.add(
              PdfTextSlice(
                page,
                begin,
                end,
                joinPrevious:
                    begin == word.start && joined.contains(word.start),
              ),
            );
          }
        }

        for (final rune in page.text.substring(word.start, wordEnd).runes) {
          final value = String.fromCharCode(rune),
              size = utf8.encode(value).length;
          if (bytes + size + 4 > maxPassageBytes) {
            appendSlice();
            if (slices.isNotEmpty) {
              passages.add(NarrationPassage.fromSlices(slices));
            }
            slices.clear();
            bytes = 0;
            begin = end;
          }
          end += value.length;
          bytes += size;
        }
        appendSlice();
        bytes++;
        // Short requests reduce pause/transition latency; prefer sentence endings.
        if (bytes >= 1200 &&
            RegExp(r'[.!?。！？]["”\x27]?$')
                .hasMatch(page.text.substring(word.start, word.end))) {
          passages.add(NarrationPassage.fromSlices(slices));
          slices.clear();
          bytes = 0;
        }
      }
      if (slices.isNotEmpty) passages.add(NarrationPassage.fromSlices(slices));
    }
    return PaperPagePlan(
      page: page,
      passages: List.unmodifiable(passages.where((p) => p.text.isNotEmpty)),
      description: options.order == PaperOrder.pdfOrder
          ? 'PDF text order'
          : two
          ? 'Two columns, left then right'
          : 'Single column, top to bottom',
      endsPaper: endsPaper,
      blocks: List.unmodifiable(blocks),
    );
  }
}
