import 'dart:convert';
import 'dart:math' as math;

import 'package:pdfrx/pdfrx.dart';

import 'source_map.dart';

enum PaperOrder { automatic, singleColumn, twoColumns, pdfOrder }

class PaperReadOptions {
  const PaperReadOptions({
    this.order = PaperOrder.automatic,
    this.stopAtReferences = true,
    this.skipCaptions = false,
  });
  final PaperOrder order;
  final bool stopAtReferences, skipCaptions;
}

class PaperPagePlan {
  PaperPagePlan({
    required this.page,
    required this.passages,
    required this.description,
    this.issue,
    this.endsPaper = false,
  });
  final PdfTextSnapshot page;
  final List<NarrationPassage> passages;
  final String description;
  final String? issue;
  final bool endsPaper;
}

class _Word {
  _Word(this.start, this.end, this.bounds);
  final int start, end;
  final PdfRect bounds;
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
  static const maxPageUnits = 200000;
  static const maxPassageBytes = 4096;

  static PaperPagePlan plan(
    PdfTextSnapshot page,
    double width,
    PaperReadOptions options,
  ) {
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
    for (final match in RegExp(r'\S+', unicode: true).allMatches(page.text)) {
      final boxes = page.boxes
          .sublist(match.start, match.end)
          .where(
            (r) =>
                r.width > 0 &&
                r.height > 0 &&
                [r.left, r.right, r.top, r.bottom].every((v) => v.isFinite),
          )
          .toList();
      if (boxes.isEmpty) continue;
      words.add(_Word(match.start, match.end, boxes.boundingRect()));
    }
    if (words.isEmpty) {
      return issue('Page ${page.page} has no usable text positions.');
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
      ordered = [
        for (final word in words) _Line([word], 0),
      ];
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
    var current = <_Word>[];
    _Line? previous;
    var endsPaper = false;
    final caption = RegExp(
      r'^(?:fig(?:ure)?\.?|table)\s+\d',
      caseSensitive: false,
    );
    for (final line in ordered) {
      final text = line.text(page);
      final originalLine = page.text
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
          RegExp(
            r'^(?:\d+[.\s]+)?(?:references|bibliography)\s*$',
            caseSensitive: false,
          ).hasMatch(
            options.order == PaperOrder.pdfOrder ? originalLine : text,
          )) {
        endsPaper = true;
        break;
      }
      final newParagraph =
          previous != null &&
          options.order != PaperOrder.pdfOrder &&
          (caption.hasMatch(text) ||
              previous.column != line.column ||
              previous.bounds.bottom - line.bounds.top > height * 1.1 ||
              line.bounds.left - previous.bounds.left > height * 1.2 ||
              line.bounds.height > height * 1.4);
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
      if (options.skipCaptions &&
          caption.hasMatch(
            paragraph
                .map((word) => page.text.substring(word.start, word.end))
                .join(' '),
          )) {
        continue;
      }
      final slices = <PdfTextSlice>[];
      var bytes = 0;
      for (final word in paragraph) {
        // Split even pathological no-whitespace runs on Unicode scalar boundaries.
        var begin = word.start, end = begin;
        for (final rune in page.text.substring(word.start, word.end).runes) {
          final value = String.fromCharCode(rune),
              size = utf8.encode(value).length;
          if (bytes + size + 4 > maxPassageBytes) {
            if (end > begin) slices.add(PdfTextSlice(page, begin, end));
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
        if (end > begin) slices.add(PdfTextSlice(page, begin, end));
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
    );
  }
}
