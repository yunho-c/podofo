import 'dart:math' as math;
import 'dart:ui';

import 'package:podoco/podoco.dart' as podoco;

import '../analysis/preview_layout_repository.dart';
import 'link_target.dart';
import 'preview_text.dart';

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
        for (final r in regions.where(
          (r) => r.model.category == podoco.RegionCategory.text,
        )) {
          final reference = r.model.nativeSubtype == 'reference_content';
          if (!reference &&
              r.model.nativeSubtype != 'reference' &&
              !RegExp(r'^\s*\[\d+\]').hasMatch(r.text)) {
            continue;
          }
          final entries = _entries(r);
          for (final entry in entries) {
            if (!identity.matchesReference(entry.text)) continue;
            // A region ending at the physical page edge cannot establish completion.
            if (entry.bounds.bottom > destination.pageSize.height - 16) {
              continue;
            }
            if (!RegExp(r'[.!?\]\)]$').hasMatch(entry.text.trim())) continue;
            candidates.add(
              _Candidate(
                identity,
                [entry.bounds],
                [r.model.id],
                reference ? 1 : 0,
              ),
            );
          }
        }
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
                    _horizontalOverlap(r.bounds, caption.bounds) >= .5 &&
                    _verticalGap(r.bounds, caption.bounds) <= 80 &&
                    !regions.any(
                      (other) =>
                          other.model.category ==
                              podoco.RegionCategory.caption &&
                          other.model.id != caption.model.id &&
                          _between(other.bounds, r.bounds, caption.bounds),
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
            (a, b) => _verticalGap(
              a.bounds,
              caption.bounds,
            ).compareTo(_verticalGap(b.bounds, caption.bounds)),
          );
          if (distinct.length > 1 &&
              _verticalGap(distinct[1].bounds, caption.bounds) >
                  _verticalGap(distinct[0].bounds, caption.bounds) + 16) {
            distinct.removeRange(1, distinct.length);
          }
          if (distinct.length != 1) continue;
          candidates.add(
            _Candidate(
              identity,
              [
                distinct.single.bounds,
                caption.bounds.expandToInclude(caption.contentBounds),
              ],
              [distinct.single.model.id, caption.model.id],
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
          candidates.add(
            _Candidate(
              identity,
              [formulas.single.bounds, number.contentBounds],
              [formulas.single.model.id, number.model.id],
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
    nearby.sort((a, b) => b.specificity.compareTo(a.specificity));
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
    // M2 permits a single union only when it does not introduce another object.
    final rect = c.bounds;
    final foreign = regions.any(
      (r) =>
          !c.ids.contains(r.model.id) &&
          !_covers(r.bounds, rect, .95) &&
          !c.parts.any((p) => _covers(p, r.bounds, .90)) &&
          _area(r.bounds.intersect(rect)) > _area(r.bounds) * .20,
    );
    if (foreign) return miss('unionContainsNeighbor');
    final padding = identity.kind == LinkTargetKind.citation ? 1.0 : 3.0;
    final crop = rect
        .inflate(padding)
        .intersect(Offset.zero & destination.pageSize);
    return ResolvedLinkTarget(
      tier: LinkTargetTier.matchedIdentity,
      kind: identity.kind,
      label: identity.label,
      reason: 'matchedIdentity',
      evidenceIdentity: evidence,
      parts: [(page: destination.page, bounds: crop)],
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
    if (year == null) return RegExp('^\\s*\\[$value\\]').hasMatch(text);
    final first = text.substring(0, math.min(80, text.length));
    return RegExp(
          '\\b${RegExp.escape(value)}\\b',
          caseSensitive: false,
        ).hasMatch(first) &&
        RegExp('\\b$year[a-z]?\\b').hasMatch(text);
  }
}

_Identity? _sourceIdentity(LinkSourceText source) {
  final selected = _clean(source.spans.map((s) => s.text).join(' '));
  final direct = RegExp(r'^(?:Citation\s*)?\[(\d+)\]$').firstMatch(selected);
  if (direct != null) {
    return _Identity(LinkTargetKind.citation, direct.group(1)!);
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
  final author = RegExp(
    r'^\(?([A-Z][A-Za-z\-]+)\s+(?:et\s+al\.?|and\s+[A-Z][A-Za-z\-]+)[,\s]*(.*)$',
  ).firstMatch(selected);
  if (author != null) {
    final year = RegExp(r'\b((?:19|20)\d{2})[a-z]?\b').firstMatch(
      '${author.group(2)}${source.after.substring(0, math.min(24, source.after.length))}',
    );
    if (year != null) {
      return _Identity(
        LinkTargetKind.citation,
        author.group(1)!,
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

class _Line {
  const _Line(this.text, this.bounds);
  final String text;
  final Rect bounds;
}

class _Region {
  _Region(this.model, PreviewTextPage page) {
    final current = StringBuffer();
    final boxes = <Rect>[];
    void flush() {
      final value = _clean(current.toString());
      if (value.isNotEmpty && boxes.isNotEmpty) {
        lines.add(_Line(value, _union(boxes)));
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
        current.write(char);
        boxes.add(box);
      } else if (char.trim().isEmpty && boxes.isNotEmpty) {
        current.write(char);
      }
    }
    flush();
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

List<_Line> _entries(_Region r) {
  final starts = <int>[];
  for (var i = 0; i < r.lines.length; i++) {
    if (RegExp(r'^\[\d+\]').hasMatch(r.lines[i].text)) starts.add(i);
  }
  if (starts.isEmpty) {
    return r.lines.isEmpty ? [] : [_Line(r.text, r.contentBounds)];
  }
  return [
    for (var i = 0; i < starts.length; i++)
      _Line(
        r.lines
            .sublist(
              starts[i],
              i + 1 < starts.length ? starts[i + 1] : r.lines.length,
            )
            .map((l) => l.text)
            .join(' '),
        _union(
          r.lines
              .sublist(
                starts[i],
                i + 1 < starts.length ? starts[i + 1] : r.lines.length,
              )
              .map((l) => l.bounds),
        ),
      ),
  ];
}

class _Candidate {
  const _Candidate(this.identity, this.parts, this.ids, [this.specificity = 0]);
  final _Identity identity;
  final List<Rect> parts;
  final List<int> ids;
  final int specificity;
  Rect get bounds => _union(parts);
}
