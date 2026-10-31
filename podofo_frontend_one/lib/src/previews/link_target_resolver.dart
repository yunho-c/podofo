import 'dart:math' as math;
import 'dart:ui';

import 'package:podoco/podoco.dart' as podoco;

import '../analysis/preview_layout_repository.dart';
import 'link_target.dart';
import 'preview_text.dart';

part 'reference_targets.dart';
part 'figure_targets.dart';
part 'source_identity.dart';
part 'section_targets.dart';

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
        final panel = identity.kind == LinkTargetKind.figure
            ? RegExp(r'^(\d+)([a-z])$').firstMatch(identity.value)
            : null;
        for (final caption in regions.where(
          (r) => r.model.category == podoco.RegionCategory.caption,
        )) {
          final match = RegExp(
            '\\b(Figure|Fig\\.?|Table)\\s+($_targetLabel)\\b',
            caseSensitive: false,
          ).firstMatch(caption.text);
          if (match == null ||
              match.start > 32 ||
              (match.group(1)!.toLowerCase() == 'table') !=
                  (identity.kind == LinkTargetKind.table)) {
            continue;
          }
          final captionLabel = _canonicalLabel(match.group(2)!);
          final parentFigure = panel != null && captionLabel == panel.group(1);
          if (captionLabel != identity.value && !parentFigure) continue;
          final components = _figureComponents(caption, regions, identity.kind);
          if (components == null ||
              (parentFigure &&
                  !_hasFigurePanel(caption, components, panel.group(2)!))) {
            continue;
          }
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
                        destination.pageSize.width * .65 &&
                    !_hasCloserEquationNumber(r, number, regions),
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
        return _resolveSection(
          destination,
          identity,
          regions,
          evidence,
          readingOrder: layout.page.readingOrder?.regionIds,
          followingText: followingText,
          followingLayout: followingLayout,
        );
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

bool _startsContinuation(String text) => RegExp(r'^[=+−–-]').hasMatch(text);

/// A nearby formula in another column may align vertically with this number.
/// Exclude it only when a distinct, closer number follows that formula in its
/// text direction. Equal-distance matches stay ambiguous; proximity alone never
/// chooses between otherwise competing formulas.
bool _hasCloserEquationNumber(
  _Region formula,
  _Region number,
  List<_Region> regions,
) {
  final lines = [...formula.lines]
    ..sort((a, b) => b.advance.dx.abs().compareTo(a.advance.dx.abs()));
  final direction = lines.isNotEmpty && lines.first.advance.dx < 0 ? -1 : 1;
  final gap = _horizontalGap(formula.bounds, number.bounds);
  return regions.any(
    (other) =>
        other.model.category == podoco.RegionCategory.formulaNumber &&
        other.model.id != number.model.id &&
        _verticalOverlap(formula.bounds, other.bounds) >= .4 &&
        (other.bounds.center.dx - formula.bounds.center.dx) * direction > 0 &&
        _horizontalGap(formula.bounds, other.bounds) + 4 < gap,
  );
}

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
  // Tight line spacing can leave no room for the preferred padding. Shrink
  // only the margin, never any selected content, before trying separate crops.
  for (final padding in [3.0, 1.0, 0.0]) {
    final union = _padTarget(
      _union(parts),
      padding,
      parts,
      ids,
      regions,
    ).intersect(page);
    if (!_containsForeign(union, parts, ids, regions)) return [union];
  }
  if (parts.length > 4) return null;
  final crops = <Rect>[];
  for (final part in parts) {
    final safe = [3.0, 1.0, 0.0]
        .map(
          (padding) =>
              _padTarget(part, padding, parts, ids, regions).intersect(page),
        )
        .where((crop) => !_containsForeign(crop, parts, ids, regions))
        .firstOrNull;
    if (safe == null) return null;
    crops.add(safe);
  }
  return crops;
}

Rect _padTarget(
  Rect content,
  double padding,
  List<Rect> selected,
  List<int> ids,
  List<_Region> regions,
) {
  var left = content.left - padding,
      top = content.top - padding,
      right = content.right + padding,
      bottom = content.bottom + padding;
  for (final r in regions) {
    if (ids.contains(r.model.id) ||
        _covers(r.bounds, content, .95) ||
        selected.any((p) => _covers(p, r.bounds, .9))) {
      continue;
    }
    // Prose model boxes can extend through whitespace after a ragged last line.
    // Their native lines constrain padding more precisely, preserving nearby
    // vector strokes (such as radical overbars) outside formula glyph boxes.
    // Textless regions and graphics still use model bounds; contained formula
    // regions remain independent obstacles. Never reduce selected content.
    final obstacles =
        r.model.category == podoco.RegionCategory.text && r.lines.isNotEmpty
        ? r.lines.map((l) => l.bounds.inflate(.5))
        : [r.bounds];
    for (final b in obstacles) {
      if (_horizontalOverlap(content, b) > 0) {
        if (b.top >= content.bottom) {
          bottom = math.min(bottom, math.max(content.bottom, b.top - .5));
        }
        if (b.bottom <= content.top) {
          top = math.max(top, math.min(content.top, b.bottom + .5));
        }
      }
      if (_verticalOverlap(content, b) > 0) {
        if (b.left >= content.right) {
          right = math.min(right, math.max(content.right, b.left - .5));
        }
        if (b.right <= content.left) {
          left = math.max(left, math.min(content.left, b.right + .5));
        }
      }
    }
  }
  return Rect.fromLTRB(left, top, right, bottom);
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
