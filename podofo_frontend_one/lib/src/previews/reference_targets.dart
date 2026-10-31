part of 'link_target_resolver.dart';

String? _referenceNumber(String text) {
  final match = RegExp(r'^\s*(?:\[(\d+)\]|(\d+)\.\s)').firstMatch(text);
  return match?.group(1) ?? match?.group(2);
}

bool _authorStart(String text) => RegExp(
  r'^(?:[\p{Lu}][\p{L}\x27’\-]+\s+){0,3}[\p{Lu}][\p{L}\x27’\-]+,\s*[\p{Lu}]|^(?:[\p{Lu}]\.\s*)+[\p{Lu}][\p{L}\x27’\-]+|^[\p{Lu}][\p{L}\x27’\-]+\s+(?:et\s+al\.?|and\s+[\p{Lu}][\p{L}\x27’\-]+)',
  unicode: true,
).hasMatch(text);

bool _dittoAuthorStart(String text) =>
    RegExp(r'^[–—-]\s*\((?:19|20)\d{2}[a-z]?\)').hasMatch(text);

class _ReferenceLine {
  const _ReferenceLine(this.line, this.region);
  final _Line line;
  final _Region region;
  Rect get bounds => line.bounds;
}

class _ReferencePart {
  _ReferencePart(this.page, this.column, this.lines);
  final int page, column;
  final List<_ReferenceLine> lines;
  Rect get bounds => _union(lines.map((l) => l.bounds));
  double get fontHeight =>
      lines.map((l) => l.bounds.height).reduce((a, b) => a + b) / lines.length;
  double get columnWidth => _union(lines.map((l) => l.region.bounds)).width;
}

class _ReferenceEntry {
  _ReferenceEntry(this.parts, {required this.hasStart, this.inheritedAuthor});
  final List<_ReferencePart> parts;
  final bool hasStart;
  final String? inheritedAuthor;
  bool boundary = false, ambiguousTail = false;
  String get text =>
      parts.expand((p) => p.lines).map((l) => l.line.text).join(' ');
  String? get authorPrefix {
    if (inheritedAuthor != null) return inheritedAuthor;
    if (!hasStart || !_authorStart(text)) return null;
    final year = RegExp(r'\b(?:19|20)\d{2}[a-z]?\b').firstMatch(text);
    return year == null
        ? null
        : text.substring(0, year.start).replaceFirst(RegExp(r'\($'), '').trim();
  }

  String get identityText =>
      inheritedAuthor == null ? text : '$inheritedAuthor $text';
  bool get terminal => RegExp(r'[.!?\]\)]$').hasMatch(text.trim());
  bool atEnd(Size pageSize) =>
      parts.last.bounds.bottom >= pageSize.height * .78;
  bool complete(Size pageSize) =>
      !ambiguousTail && (boundary || (terminal && !atEnd(pageSize)));
}

/// Group only text already classified as references (or explicitly numbered).
/// Layout parents and contained children may duplicate the same native glyphs.
List<_ReferenceEntry> _referenceEntries(
  List<_Region> regions,
  int page,
  Size size, {
  bool continuation = false,
}) {
  final lines = <_ReferenceLine>[];
  final references =
      regions
          .where(
            (r) =>
                r.model.category == podoco.RegionCategory.text &&
                ([
                      'reference',
                      'reference_content',
                    ].contains(r.model.nativeSubtype) ||
                    _referenceNumber(r.text) != null ||
                    _hangingReference(r) ||
                    (continuation && _leadingContinuation(r, regions, size))),
          )
          .toList()
        ..sort((a, b) => _area(a.bounds).compareTo(_area(b.bounds)));
  for (final region in references) {
    for (final line in region.lines) {
      if (!lines.any(
        (l) =>
            l.line.text == line.text &&
            _covers(l.bounds, line.bounds, .9) &&
            _covers(line.bounds, l.bounds, .9),
      )) {
        lines.add(_ReferenceLine(line, region));
      }
    }
  }
  lines.sort((a, b) => a.bounds.left.compareTo(b.bounds.left));
  final columns = <List<_ReferenceLine>>[];
  for (final line in lines) {
    if (columns.isEmpty ||
        line.bounds.left - columns.last.first.bounds.left >
            math.max(36, size.width * .08)) {
      columns.add([]);
    }
    columns.last.add(line);
  }
  final entries = <_ReferenceEntry>[];
  for (var column = 0; column < columns.length; column++) {
    final sorted = columns[column]
      ..sort((a, b) => a.bounds.top.compareTo(b.bounds.top));
    final left = sorted.map((l) => l.bounds.left).reduce(math.min);
    _ReferencePart? part;
    for (final line in sorted) {
      final starts =
          _referenceNumber(line.line.text) != null ||
          (line.bounds.left <= left + 4 &&
              (_authorStart(line.line.text) ||
                  _dittoAuthorStart(line.line.text)));
      final previous = entries.lastOrNull;
      final lastPart = previous?.parts.last;
      final sameColumn = lastPart?.column == column;
      final close =
          lastPart != null &&
          sameColumn &&
          line.bounds.top - lastPart.bounds.bottom <=
              math.max(24, lastPart.fontHeight * 3);
      final transition =
          lastPart != null &&
          !sameColumn &&
          lastPart.column == column - 1 &&
          lastPart.bounds.bottom >= size.height * .78 &&
          line.bounds.top <= size.height * .2 &&
          _compatibleReferenceFont(lastPart, line.bounds.height);
      if (starts) {
        if (previous != null) {
          if (!sameColumn &&
              previous.atEnd(size) &&
              (!previous.terminal || line.bounds.top > size.height * .12)) {
            previous.ambiguousTail = true;
          } else {
            previous.boundary = true;
          }
        }
        part = _ReferencePart(page, column, [line]);
        final ditto = _dittoAuthorStart(line.line.text);
        final inherited = ditto && close ? previous?.authorPrefix : null;
        entries.add(
          _ReferenceEntry(
            [part],
            hasStart: !ditto || inherited != null,
            inheritedAuthor: inherited,
          ),
        );
      } else if (previous != null && (close || transition)) {
        if (transition) {
          part = _ReferencePart(page, column, [line]);
          previous.parts.add(part);
        } else {
          lastPart.lines.add(line);
          part = lastPart;
        }
      } else {
        if (previous != null) previous.ambiguousTail = true;
        part = _ReferencePart(page, column, [line]);
        entries.add(_ReferenceEntry([part], hasStart: false));
      }
    }
  }
  return entries;
}

bool _hangingReference(_Region region) =>
    region.lines.length > 1 &&
    _authorStart(region.lines.first.text) &&
    RegExp(r'\b(?:19|20)\d{2}[a-z]?\b').hasMatch(region.text) &&
    region.lines
        .skip(1)
        .any(
          (line) =>
              line.bounds.left - region.lines.first.bounds.left >= 4 &&
              line.bounds.left - region.lines.first.bounds.left <= 40,
        );

// A generic text region can be a continuation only at the start of the next
// page, immediately before another recognizable bibliography entry. This rule
// is enabled only after the first page has justified a continuation request.
bool _leadingContinuation(_Region region, List<_Region> regions, Size size) =>
    region.lines.isNotEmpty &&
    region.bounds.top <= size.height * .12 &&
    region.bounds.left <= size.width * .25 &&
    _referenceNumber(region.text) == null &&
    !_authorStart(region.text) &&
    regions.any(
      (next) =>
          next.model.category == podoco.RegionCategory.text &&
          (_referenceNumber(next.text) != null || _hangingReference(next)) &&
          next.bounds.top >= region.bounds.bottom &&
          next.bounds.top - region.bounds.bottom <= 60 &&
          (next.bounds.left - region.bounds.left).abs() <= 32 &&
          _horizontalOverlap(next.bounds, region.bounds) > .5 &&
          !regions.any(
            (other) =>
                other.model.category == podoco.RegionCategory.heading &&
                _between(other.bounds, region.bounds, next.bounds),
          ),
    );

bool _compatibleReferenceFont(_ReferencePart part, double height) =>
    height >= part.fontHeight * .75 && height <= part.fontHeight * 1.35;

ResolvedLinkTarget _resolveReference(
  PreviewDestination destination,
  _Identity identity,
  List<_Region> regions,
  Object? evidence, {
  PreviewTextPage? followingText,
  PreviewLayoutEvidence? followingLayout,
}) {
  var usedEvidence = evidence;
  ResolvedLinkTarget miss(String reason, {int? continuation}) =>
      ResolvedLinkTarget(
        tier: LinkTargetTier.unresolved,
        reason: reason,
        evidenceIdentity: usedEvidence,
        continuationPage: continuation,
      );
  final entries = _referenceEntries(
    regions,
    destination.page,
    destination.pageSize,
  );
  final matches = entries
      .where(
        (e) =>
            e.hasStart &&
            identity.matchesReference(e.identityText) &&
            (destination.y == null ||
                e.parts.any(
                  (p) =>
                      destination.y! >= p.bounds.top - 96 &&
                      destination.y! <= p.bounds.bottom + 96,
                )),
      )
      .toList();
  if (matches.length != 1) {
    return miss(matches.isEmpty ? 'noReferenceMatch' : 'competingReferences');
  }
  final entry = matches.single;
  final nextRegions = <_Region>[];
  Size? nextSize;
  if (!entry.complete(destination.pageSize)) {
    // A matched last entry near the bottom of the final reference column is
    // the only reason to inspect a second page. No third page is ever requested.
    if (entry.ambiguousTail ||
        !identical(entry, entries.last) ||
        !entry.atEnd(destination.pageSize)) {
      return miss('uncertainReferenceBoundary');
    }
    if (followingText == null || followingLayout == null) {
      return miss(
        'referenceNeedsContinuation',
        continuation: destination.page + 1,
      );
    }
    if (followingText.snapshot.page != destination.page + 1 ||
        followingLayout.page.page.key.pageIndex != destination.page) {
      return miss('invalidContinuationPage');
    }
    usedEvidence = (evidence, followingLayout.identity);
    final space = followingLayout.page.page.space;
    nextSize = Size(space.width, space.height);
    nextRegions.addAll(
      followingLayout.page.regions.map((r) => _Region(r, followingText)),
    );
    final following = _referenceEntries(
      nextRegions,
      destination.page + 1,
      nextSize,
      continuation: true,
    );
    if (following.isEmpty ||
        following.first.parts.first.bounds.top > nextSize.height * .12 ||
        following.first.parts.first.bounds.left > nextSize.width * .25) {
      return miss('missingReferenceContinuation');
    }
    final first = following.first;
    if (first.hasStart) {
      if (identity.matchesReference(first.identityText)) {
        return miss('competingReferences');
      }
      if (!entry.terminal) return miss('uncertainReferenceBoundary');
      // A new entry at the start of the next page establishes the old boundary.
      entry.boundary = true;
    } else {
      final tail = entry.parts.last, head = first.parts.first;
      if (!_compatibleReferenceFont(tail, head.fontHeight)) {
        return miss('referenceFontMismatch');
      }
      if (head.columnWidth / tail.columnWidth < .6 ||
          head.columnWidth / tail.columnWidth > 1.7) {
        return miss('referenceColumnMismatch');
      }
      if (!first.complete(nextSize)) {
        return miss('incompleteReferenceContinuation');
      }
      entry.parts.addAll(first.parts);
      entry.boundary = true;
    }
  }
  if (entry.parts.length > 4) return miss('referencePartLimit');
  final result = <({int page, Rect bounds})>[];
  for (final part in entry.parts) {
    final onFirst = part.page == destination.page;
    final selected = entry.parts.where((p) => p.page == part.page).toList();
    final crop = part.bounds
        .inflate(1)
        .intersect(Offset.zero & (onFirst ? destination.pageSize : nextSize!));
    if (_containsForeign(
      crop,
      selected.map((p) => p.bounds).toList(),
      selected.expand((p) => p.lines.map((l) => l.region.model.id)).toList(),
      onFirst ? regions : nextRegions,
    )) {
      return miss('referenceContainsNeighbor');
    }
    result.add((page: part.page, bounds: crop));
  }
  return ResolvedLinkTarget(
    tier: LinkTargetTier.matchedIdentity,
    kind: identity.kind,
    label: identity.label,
    reason: 'matchedCompleteReference',
    evidenceIdentity: usedEvidence,
    parts: result,
  );
}
