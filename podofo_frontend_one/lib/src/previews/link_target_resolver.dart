import 'dart:math' as math;
import 'dart:ui';

import 'package:podoco/podoco.dart' as podoco;

import '../analysis/preview_layout_repository.dart';
import 'link_target.dart';
import 'preview_text.dart';

part 'reference_targets.dart';

/// Pure selection over owned PDF text and layout. Scores are detector evidence,
/// never interpreted as a probability that a source link names an object.
class LinkTargetResolver {
  const LinkTargetResolver();
  ResolvedLinkTarget resolve(
    PreviewDestination? destination, {
    Object? evidenceIdentity,
    LinkSourceText? source,
    PreviewTextPage? text,
    PreviewLayoutEvidence? layout,
    PreviewTextPage? followingText,
    PreviewLayoutEvidence? followingLayout,
  }) {
    final evidence = layout?.identity ?? evidenceIdentity;
    ResolvedLinkTarget miss(String reason) => ResolvedLinkTarget(
      tier: LinkTargetTier.unresolved,
      reason: reason,
      evidenceIdentity: evidence,
    );
    if (destination?.area case final area?) {
      return ResolvedLinkTarget(
        tier: LinkTargetTier.explicitArea,
        kind: LinkTargetKind.explicitArea,
        reason: 'explicitFitR',
        evidenceIdentity: evidence,
        parts: [(page: destination!.page, bounds: area)],
      );
    }
    if (destination == null) return miss('invalidDestination');
    if (layout == null || text == null || source == null) {
      return miss('missingEvidence');
    }
    if (source.truncated) return miss('truncatedSource');
    final identity = _sourceIdentity(source);
    if (identity == null) return miss('ambiguousSource');
    final regions = layout.page.regions.map((r) => _Region(r, text)).toList();
    final candidates = <_Candidate>[];
    switch (identity.kind) {
      case LinkTargetKind.citation:
        return _resolveReference(
          destination,
          identity,
          regions,
          evidence,
          followingText: followingText,
          followingLayout: followingLayout,
        );
      case LinkTargetKind.figure:
      case LinkTargetKind.table:
        for (final caption in regions.where(
          (r) => r.model.category == podoco.RegionCategory.caption,
        )) {
          final match = RegExp(
            r'\b(Figure|Fig\.?|Table)\s+(\d+[a-z]?)\b',
            caseSensitive: false,
          ).firstMatch(caption.text);
          if (match == null ||
              match.start > 32 ||
              match.group(2)!.toLowerCase() != identity.value ||
              (match.group(1)!.toLowerCase() == 'table') !=
                  (identity.kind == LinkTargetKind.table)) {
            continue;
          }
          final type = identity.kind == LinkTargetKind.figure
              ? podoco.RegionCategory.figure
              : podoco.RegionCategory.table;
          final visuals = regions
              .where(
                (r) =>
                    r.model.category == type &&
                    _captionOverlap(r.bounds, caption) >= .5 &&
                    _captionGap(r.bounds, caption) <= 80 &&
                    !regions.any(
                      (other) =>
                          other.model.category ==
                              podoco.RegionCategory.caption &&
                          other.model.id != caption.model.id &&
                          _captionOverlap(r.bounds, other) >= .5 &&
                          _captionGap(r.bounds, other) + 3 <
                              _captionGap(r.bounds, caption),
                    ) &&
                    !regions.any(
                      (other) =>
                          other.model.category ==
                              podoco.RegionCategory.caption &&
                          other.model.id != caption.model.id &&
                          _captionBetween(other.bounds, r.bounds, caption),
                    ),
              )
              .toList();
          // Detectors can emit both image/chart parents and contained panels.
          final distinct = <_Region>[];
          visuals.sort((a, b) => _area(b.bounds).compareTo(_area(a.bounds)));
          for (final v in visuals) {
            if (!distinct.any((p) => _covers(p.bounds, v.bounds, .94))) {
              distinct.add(v);
            }
          }
          distinct.sort(
            (a, b) => _captionGap(
              a.bounds,
              caption,
            ).compareTo(_captionGap(b.bounds, caption)),
          );
          if (distinct.isEmpty || distinct.length > 3) continue;
          // Panels must share a band on the same side of their caption. A
          // visual on the opposite side is a competing figure, not a panel.
          if (distinct.length > 1 &&
              !distinct
                  .skip(1)
                  .every(
                    (v) => _samePanelBand(
                      distinct.first.bounds,
                      v.bounds,
                      caption,
                    ),
                  )) {
            continue;
          }
          distinct.sort((a, b) => _readingCompare(a.bounds, b.bounds));
          final components = [...distinct, caption]
            ..sort((a, b) => _readingCompare(a.bounds, b.bounds));
          candidates.add(
            _Candidate(
              identity,
              components
                  .map((r) => r.bounds.expandToInclude(r.contentBounds))
                  .toList(),
              components.map((r) => r.model.id).toList(),
            ),
          );
        }
      case LinkTargetKind.equation:
        for (final number in regions.where(
          (r) => r.model.category == podoco.RegionCategory.formulaNumber,
        )) {
          if (!_exactNumber(number.text, identity.value)) continue;
          final formulas = regions
              .where(
                (r) =>
                    r.model.category == podoco.RegionCategory.formula &&
                    r.model.displayKind != podoco.FormulaDisplayKind.inline &&
                    _verticalOverlap(r.bounds, number.bounds) >= .4 &&
                    _horizontalGap(r.bounds, number.bounds) <
                        destination.pageSize.width * .65,
              )
              .toList();
          if (formulas.length != 1) continue;
          final group = <_Region>[formulas.single];
          // Grow through short aligned line gaps. Another formula number or
          // intervening prose is a boundary, including a number on an earlier
          // line of the next equation.
          var growing = true, ambiguous = false;
          while (growing) {
            growing = false;
            final bounds = _union(group.map((r) => r.bounds));
            final neighbors = regions
                .where(
                  (r) =>
                      r.model.category == podoco.RegionCategory.formula &&
                      r.model.displayKind != podoco.FormulaDisplayKind.inline &&
                      !group.contains(r) &&
                      _horizontalOverlap(bounds, r.bounds) >= .6 &&
                      _verticalGap(bounds, r.bounds) <= 20 &&
                      group.any((member) => _equationContinuation(member, r)) &&
                      !regions.any(
                        (other) =>
                            other.model.id != number.model.id &&
                            other.model.category ==
                                podoco.RegionCategory.formulaNumber &&
                            _verticalOverlap(other.bounds, r.bounds) >= .3,
                      ) &&
                      !regions.any(
                        (other) =>
                            other.model.category ==
                                podoco.RegionCategory.text &&
                            _between(other.bounds, bounds, r.bounds),
                      ),
                )
                .toList();
            if (neighbors.length > 2) {
              ambiguous = true;
              break;
            }
            if (neighbors.isNotEmpty) {
              group.addAll(neighbors);
              growing = true;
            }
          }
          group.sort((a, b) => _readingCompare(a.bounds, b.bounds));
          if (ambiguous || _startsContinuation(group.first.text)) continue;
          candidates.add(
            _Candidate(
              identity,
              [
                ...group.map((r) => r.bounds.expandToInclude(r.contentBounds)),
                number.contentBounds,
              ],
              [...group.map((r) => r.model.id), number.model.id],
            ),
          );
        }
      case LinkTargetKind.section:
        for (final heading in regions.where(
          (r) => r.model.category == podoco.RegionCategory.heading,
        )) {
          if (!RegExp('^${RegExp.escape(identity.value)}[.]?(?:\\s|\$)')
              .hasMatch(heading.text)) {
            continue;
          }
          final paragraphs =
              regions
                  .where(
                    (r) =>
                        r.model.category == podoco.RegionCategory.text &&
                        ![
                          'reference',
                          'reference_content',
                        ].contains(r.model.nativeSubtype) &&
                        r.bounds.top >= heading.bounds.bottom - 2 &&
                        r.bounds.top - heading.bounds.bottom <= 50 &&
                        (r.bounds.left - heading.bounds.left).abs() <=
                            math.max(14, heading.bounds.width * .15),
                  )
                  .toList()
                ..sort((a, b) => a.bounds.top.compareTo(b.bounds.top));
          if (paragraphs.isEmpty) continue;
          final p = paragraphs.first;
          if (paragraphs.length > 1 &&
              (paragraphs[1].bounds.top - p.bounds.top).abs() < 3) {
            continue;
          }
          if (p.bounds.bottom > destination.pageSize.height - 16 ||
              !RegExp(r'[.!?\]\)]$').hasMatch(p.text)) {
            continue;
          }
          candidates.add(
            _Candidate(
              identity,
              [heading.contentBounds, p.contentBounds],
              [heading.model.id, p.model.id],
            ),
          );
        }
      case LinkTargetKind.explicitArea:
        break;
    }
    // Exact source identity can disambiguate shared coordinates. Constrain by
    // target page and vertical neighborhood, never a fabricated unknown axis.
    final nearby = candidates
        .where(
          (c) =>
              destination.y == null ||
              (destination.y! >= c.bounds.top - 96 &&
                  destination.y! <= c.bounds.bottom + 96),
        )
        .toList();
    final unique = <_Candidate>[];
    for (final c in nearby) {
      if (!unique.any(
        (p) =>
            _covers(p.bounds, c.bounds, .9) && _covers(c.bounds, p.bounds, .9),
      )) {
        unique.add(c);
      }
    }
    if (unique.length != 1) {
      return miss(unique.isEmpty ? 'noCompleteMatch' : 'competingMatches');
    }
    final c = unique.single;
    final parts = _safeParts(c.parts, c.ids, regions, destination.pageSize);
    if (parts == null) return miss('regionsContainNeighbor');
    return ResolvedLinkTarget(
      tier: LinkTargetTier.matchedIdentity,
      kind: identity.kind,
      label: identity.label,
      reason: 'matchedIdentity',
      evidenceIdentity: evidence,
      parts: [for (final part in parts) (page: destination.page, bounds: part)],
    );
  }
}

class _Identity {
  const _Identity(this.kind, this.value, {this.year});
  final LinkTargetKind kind;
  final String value;
  final String? year;
  String get label => switch (kind) {
    LinkTargetKind.citation =>
      year == null ? 'Reference [$value]' : '$value ($year)',
    LinkTargetKind.figure => 'Figure $value',
    LinkTargetKind.table => 'Table $value',
    LinkTargetKind.equation => 'Equation ($value)',
    LinkTargetKind.section => 'Section $value',
    LinkTargetKind.explicitArea => 'Target',
  };
  bool matchesReference(String text) {
    if (year == null) return _referenceNumber(text) == value;
    final first = text
        .substring(0, math.min(80, text.length))
        .replaceFirst(RegExp(r'^\s*(?:\[\d+\]|\d+\.)\s*'), '')
        .split(RegExp(r',|\s+(?:and|&)\s+'))
        .first;
    return RegExp(
          '(?:^|[^\\p{L}\\p{N}])${RegExp.escape(value)}(?=\$|[^\\p{L}\\p{N}])',
          caseSensitive: false,
          unicode: true,
        ).hasMatch(first) &&
        RegExp('\\b${RegExp.escape(year!)}\\b').hasMatch(text);
  }
}

_Identity? _sourceIdentity(LinkSourceText source) {
  final selected = _clean(source.spans.map((s) => s.text).join(' '));
  final direct = RegExp(r'^(?:Citation\s*)?\[(\d+)\]$').firstMatch(selected);
  if (direct != null) {
    return _Identity(LinkTargetKind.citation, direct.group(1)!);
  }
  if (RegExp(r'^\d+$').hasMatch(selected) &&
      RegExp(r'\[\s*$').hasMatch(source.before) &&
      RegExp(r'^\s*\]').hasMatch(source.after)) {
    return _Identity(LinkTargetKind.citation, selected);
  }
  final named = RegExp(
    r'\b(Figure|Fig\.?|Table|Equation|Eq\.?|Section|Sec\.?)\s*\(?\s*(\d+(?:\.\d+)*[a-z]?)\b',
    caseSensitive: false,
  );
  final directNames = named.allMatches(selected).toList();
  if (directNames.length > 1) return null;
  var match = directNames.singleOrNull;
  if (match == null &&
      RegExp(r'^\(?\d+(?:\.\d+)*[a-z]?[),.]*$').hasMatch(selected)) {
    final before = source.before.length > 32
        ? source.before.substring(source.before.length - 32)
        : source.before;
    final combined = '$before$selected';
    final matches = named
        .allMatches(combined)
        .where((m) => m.end >= before.length)
        .toList();
    if (matches.length == 1) match = matches.single;
  }
  if (match != null) {
    if (RegExp(r'\b\d+(?:\.\d+)*[a-z]?\b').allMatches(selected).length > 1) {
      return null;
    }
    final prefix = match.group(1)!.toLowerCase();
    final kind = prefix.startsWith('fig')
        ? LinkTargetKind.figure
        : prefix.startsWith('tab')
        ? LinkTargetKind.table
        : prefix.startsWith('eq')
        ? LinkTargetKind.equation
        : LinkTargetKind.section;
    return _Identity(kind, match.group(2)!.toLowerCase());
  }
  final equation = RegExp(r'^\((\d+[a-z]?)\)$').firstMatch(selected);
  if (equation != null) {
    return _Identity(LinkTargetKind.equation, equation.group(1)!);
  }
  // Some PDFs link only the year, leaving the author immediately before it.
  final authorText = RegExp(r'^\(?(?:19|20)\d{2}[a-z]?\)?$').hasMatch(selected)
      ? '${source.before.substring(math.max(0, source.before.length - 80))}$selected'
      : selected;
  final author = RegExp(
    r'(?:^|\s|\()([\p{Lu}][\p{L}\-\x27’]+)(?:\s+(?:et\s+al\.?|and\s+[\p{Lu}][\p{L}\-\x27’]+))?[,\s]*\(?((?:19|20)\d{2}[a-z]?)\)?$',
    unicode: true,
  ).firstMatch(authorText);
  if (author != null) {
    return _Identity(
      LinkTargetKind.citation,
      author.group(1)!,
      year: author.group(2),
    );
  }
  final authorOnly = RegExp(
    r'^\(?([\p{Lu}][\p{L}\-\x27’]+)\s+(?:et\s+al\.?|and\s+[\p{Lu}][\p{L}\-\x27’]+)[,\s]*$',
    unicode: true,
  ).firstMatch(selected);
  if (authorOnly != null) {
    final year = RegExp(
      r'^\s*\(?((?:19|20)\d{2}[a-z]?)\b',
    ).firstMatch(source.after.substring(0, math.min(24, source.after.length)));
    if (year != null) {
      return _Identity(
        LinkTargetKind.citation,
        authorOnly.group(1)!,
        year: year.group(1),
      );
    }
  }
  return null;
}

String _clean(String s) =>
    s.replaceAll('\u0002', '-').replaceAll(RegExp(r'\s+'), ' ').trim();
bool _exactNumber(String s, String n) =>
    RegExp('^\\(?${RegExp.escape(n)}\\)?[.]?\$').hasMatch(s.trim());
double _area(Rect r) => r.isEmpty ? 0 : r.width * r.height;
bool _covers(Rect a, Rect b, double fraction) =>
    _area(b) > 0 && _area(a.intersect(b)) / _area(b) >= fraction;
double _horizontalOverlap(Rect a, Rect b) =>
    math.max(0, math.min(a.right, b.right) - math.max(a.left, b.left)) /
    math.min(a.width, b.width);
double _verticalOverlap(Rect a, Rect b) =>
    math.max(0, math.min(a.bottom, b.bottom) - math.max(a.top, b.top)) /
    math.min(a.height, b.height);
double _verticalGap(Rect a, Rect b) =>
    math.max(0, math.max(a.top - b.bottom, b.top - a.bottom));
double _horizontalGap(Rect a, Rect b) =>
    math.max(0, math.max(a.left - b.right, b.left - a.right));
bool _between(Rect c, Rect a, Rect b) =>
    c.center.dy > math.min(a.center.dy, b.center.dy) &&
    c.center.dy < math.max(a.center.dy, b.center.dy) &&
    _horizontalOverlap(c, a) > .5;
Rect _union(Iterable<Rect> rects) =>
    rects.reduce((a, b) => a.expandToInclude(b));

int _readingCompare(Rect a, Rect b) => _verticalOverlap(a, b) > .5
    ? a.left.compareTo(b.left)
    : a.top.compareTo(b.top);
bool _sideways(_Region caption) =>
    caption.lines.isNotEmpty &&
    caption.lines.where((l) => l.bounds.height > l.bounds.width * 2).length >
        caption.lines.length / 2;
double _captionGap(Rect visual, _Region caption) => _sideways(caption)
    ? _horizontalGap(visual, caption.bounds)
    : _verticalGap(visual, caption.bounds);
double _captionOverlap(Rect visual, _Region caption) => _sideways(caption)
    ? _verticalOverlap(visual, caption.bounds)
    : _horizontalOverlap(visual, caption.bounds);
bool _captionBetween(Rect other, Rect visual, _Region caption) =>
    _sideways(caption)
    ? other.center.dx > math.min(visual.center.dx, caption.bounds.center.dx) &&
          other.center.dx <
              math.max(visual.center.dx, caption.bounds.center.dx) &&
          _verticalOverlap(other, visual) > .5
    : _between(other, visual, caption.bounds);
bool _samePanelBand(Rect a, Rect b, _Region caption) => _sideways(caption)
    ? _horizontalOverlap(a, b) > .6 &&
          (a.center.dx - caption.bounds.center.dx).sign ==
              (b.center.dx - caption.bounds.center.dx).sign
    : _verticalOverlap(a, b) > .6 &&
          (a.center.dy - caption.bounds.center.dy).sign ==
              (b.center.dy - caption.bounds.center.dy).sign;

bool _startsContinuation(String text) => RegExp(r'^[=+−–-]').hasMatch(text);
bool _equationContinuation(_Region a, _Region b) {
  final upper = a.bounds.top < b.bounds.top ? a : b;
  final lower = identical(upper, a) ? b : a;
  return _startsContinuation(lower.text) ||
      RegExp(r'[=+−–-]$').hasMatch(upper.text);
}

bool _containsForeign(
  Rect rect,
  List<Rect> selected,
  List<int> ids,
  List<_Region> regions,
) => regions.any(
  (r) =>
      !ids.contains(r.model.id) &&
      !_covers(r.bounds, rect, .95) &&
      !selected.any((p) => _covers(p, r.bounds, .90)) &&
      _area(r.bounds.intersect(rect)) > _area(r.bounds) * .20,
);

List<Rect>? _safeParts(
  List<Rect> parts,
  List<int> ids,
  List<_Region> regions,
  Size pageSize,
) {
  final page = Offset.zero & pageSize;
  final union = _union(parts).inflate(3).intersect(page);
  if (!_containsForeign(union, parts, ids, regions)) return [union];
  if (parts.length > 4) return null;
  final crops = parts.map((p) => p.inflate(3).intersect(page)).toList();
  if (crops.any((p) => _containsForeign(p, parts, ids, regions))) return null;
  return crops;
}

class _Line {
  const _Line(this.text, this.bounds, this.advance);
  final String text;
  final Rect bounds;
  final Offset advance;
}

class _Region {
  _Region(this.model, PreviewTextPage page) {
    final current = StringBuffer();
    final boxes = <Rect>[];
    void flush() {
      final value = _clean(current.toString());
      if (value.isNotEmpty && boxes.isNotEmpty) {
        lines.add(
          _Line(value, _union(boxes), boxes.last.center - boxes.first.center),
        );
      }
      current.clear();
      boxes.clear();
    }

    for (var i = 0; i < page.snapshot.text.length; i++) {
      final char = page.snapshot.text[i], box = page.boxes[i];
      if (char == '\n' || char == '\r') {
        flush();
        continue;
      }
      if (!box.isEmpty && bounds.inflate(1).contains(box.center)) {
        if (boxes.isNotEmpty &&
            (box.left - boxes.last.right > math.max(24, bounds.width * .12) ||
                ((box.center.dy - boxes.last.center.dy).abs() >
                        math.max(box.height, boxes.last.height) * .8 &&
                    (box.center.dx - boxes.last.center.dx).abs() >
                        math.max(box.width, boxes.last.width) * 2))) {
          // PDFium may join columns or omit the newline at a discretionary
          // hyphen. Recover physical line boundaries from glyph geometry.
          flush();
        }
        current.write(char);
        boxes.add(box);
      } else if (char.trim().isEmpty && boxes.isNotEmpty) {
        current.write(char);
      }
    }
    flush();
    if (lines.isNotEmpty) {
      final vertical = lines
          .where((l) => l.advance.dy.abs() > l.advance.dx.abs() * 2)
          .toList();
      if (vertical.length > lines.length / 2) {
        final down = vertical.first.advance.dy > 0;
        lines.sort(
          (a, b) => down
              ? b.bounds.center.dx.compareTo(a.bounds.center.dx)
              : a.bounds.center.dx.compareTo(b.bounds.center.dx),
        );
      } else if (lines.where((l) => l.advance.dx < 0).length >
          lines.length / 2) {
        lines.sort((a, b) => b.bounds.center.dy.compareTo(a.bounds.center.dy));
      }
    }
  }
  final podoco.LayoutRegion model;
  final lines = <_Line>[];
  Rect get bounds => Rect.fromLTRB(
    model.bounds.left,
    model.bounds.top,
    model.bounds.right,
    model.bounds.bottom,
  );
  Rect get contentBounds =>
      lines.isEmpty ? bounds : _union(lines.map((l) => l.bounds));
  String get text => lines.map((l) => l.text).join(' ');
}

class _Candidate {
  const _Candidate(this.identity, this.parts, this.ids);
  final _Identity identity;
  final List<Rect> parts;
  final List<int> ids;
  Rect get bounds => _union(parts);
}
