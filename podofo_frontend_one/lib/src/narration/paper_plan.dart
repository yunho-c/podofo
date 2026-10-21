import 'dart:convert';
import 'dart:math' as math;

import 'package:pdfrx/pdfrx.dart';

import 'source_map.dart';
import 'running_matter.dart';

class PaperReadOptions {
  const PaperReadOptions({
    this.stopAtReferences = true,
    this.skipCaptions = false,
    this.skipRunningMatter = true,
  });
  final bool stopAtReferences, skipCaptions, skipRunningMatter;

  /// Value identity for shared page work and compact passage descriptors.
  String get key =>
      '${PaperPlanner.version}:pdfOrder:$stopAtReferences:$skipCaptions:$skipRunningMatter';
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
  _Line(this.words);
  final List<_Word> words;
  late final PdfRect bounds = words
      .map((w) => w.bounds)
      .toList()
      .boundingRect();
  String text(PdfTextSnapshot page) =>
      words.map((w) => page.text.substring(w.start, w.end)).join(' ');
}

/// Preserve the extracted PDF sequence. Geometry only separates paragraphs;
/// it never sorts words, infers columns, or changes reading order.
abstract final class PaperPlanner {
  static const version = 3;
  static const maxPageUnits = 200000;
  static const maxPassageBytes = 4096;

  static PaperPagePlan plan(
    PdfTextSnapshot page,
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
      // PDFium can join a wrapped word with U+0002 and no newline. Keep
      // separate visual runs for paragraph boundaries and source mapping,
      // while retaining their source order and joining the spoken slices.
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
    final ordered = <_Line>[];
    var sourceLine = <_Word>[];
    for (final word in words) {
      if (sourceLine.isNotEmpty &&
          page.text.substring(sourceLine.last.end, word.start).contains('\n')) {
        ordered.add(_Line(sourceLine));
        sourceLine = [];
      }
      sourceLine.add(word);
    }
    if (sourceLine.isNotEmpty) ordered.add(_Line(sourceLine));

    final paragraphs = <List<_Word>>[];
    final captionStarts = <int>{};
    final blocks = <PaperReadingBlock>[
      if (options.skipRunningMatter)
        for (final line in runningMatter)
          PaperReadingBlock(PaperBlockKind.runningMatter, [
            PdfTextSlice(page, line.start, line.end),
          ], included: false),
    ];
    var current = <_Word>[];
    _Line? previous;
    var endsPaper = false, captionBody = false;
    final caption = RegExp(
      // Require a label separator or a standalone label. Body sentences such
      // as 'Table 4 lists the results' must stay readable.
      r'^(?:fig(?:ure)?\.?|table)\s+(?:\d+|[IVXLCDM]+)(?:[.:](?:\s|$)|\s*$)',
      caseSensitive: false,
    );
    final heading = RegExp(
      r'^(?:(?:\d+(?:\.\d+)*|[IVXLCDM]+)[.\s]+)?(?:abstract|introduction|background|methods?|materials and methods|results?|discussion|conclusions?|acknowledg(?:e)?ments?)\s*$',
      caseSensitive: false,
    );
    final references = RegExp(
      r'^(?:(?:\d+|[IVXLCDM]+)[.\s]+)?(?:references|bibliography)\s*$',
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
      if (options.stopAtReferences && references.hasMatch(originalLine)) {
        endsPaper = true;
        blocks.add(
          PaperReadingBlock(PaperBlockKind.references, [
            for (final word in line.words)
              PdfTextSlice(page, word.start, word.end),
          ], included: false),
        );
        break;
      }
      // Segment adjacent source lines without moving them. A return upwards
      // or a move to a disjoint horizontal region can be a column transition.
      // End captions at a larger body-text size or a change in alignment.
      // Smaller glyph boxes can just be an all-small-caps continuation.
      // Centered continuation lines may have different left edges.
      final before = previous;
      final newParagraph =
          before != null &&
          !line.words.first.joinPrevious &&
          (caption.hasMatch(text) ||
              heading.hasMatch(text) ||
              heading.hasMatch(before.text(page)) ||
              references.hasMatch(text) ||
              references.hasMatch(before.text(page)) ||
              RegExp(r'\n[ \t\r]*\n').hasMatch(
                page.text.substring(
                  before.words.last.end,
                  line.words.first.start,
                ),
              ) ||
              line.bounds.top > before.bounds.top + height * .55 ||
              before.bounds.bottom - line.bounds.top > height * .75 ||
              line.bounds.left >= before.bounds.right ||
              line.bounds.right <= before.bounds.left ||
              (!captionBody &&
                  line.bounds.left - before.bounds.left > height * 1.2) ||
              (captionBody &&
                  (((line.bounds.left - before.bounds.left).abs() >
                              height * 1.2 &&
                          (line.bounds.center.x - before.bounds.center.x)
                                  .abs() >
                              height * 1.2) ||
                      line.bounds.height > before.bounds.height * 1.2)));
      if (newParagraph && current.isNotEmpty) {
        paragraphs.add(current);
        current = [];
      }
      if (current.isEmpty) {
        captionBody = caption.hasMatch(text);
        if (captionBody) captionStarts.add(line.words.first.start);
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
      final isCaption = captionStarts.contains(paragraph.first.start);
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
      description: 'PDF text order',
      endsPaper: endsPaper,
      blocks: List.unmodifiable(blocks),
    );
  }
}
