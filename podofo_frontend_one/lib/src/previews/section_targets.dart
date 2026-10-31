part of 'link_target_resolver.dart';

bool _sectionText(_Region r) =>
    r.model.category == podoco.RegionCategory.text &&
    ![
      'reference',
      'reference_content',
      'header',
      'footer',
      'footnote',
    ].contains(r.model.nativeSubtype) &&
    r.lines.isNotEmpty;

bool _sectionTerminal(_Region r) => RegExp(r'[.!?:\]\)]$').hasMatch(r.text);

String? _sectionHeadingLabel(_Region heading) =>
    RegExp('^($_targetLabel)[.]?(?:\\s|\$)').firstMatch(heading.text)?.group(1);

List<_Region>? _sectionOpeningHeadings(
  _Region heading,
  _Region paragraph,
  List<_Region> regions,
) {
  final between =
      regions
          .where(
            (r) =>
                r.model.category == podoco.RegionCategory.heading &&
                r.model.id != heading.model.id &&
                r.bounds.top >= heading.bounds.bottom - 2 &&
                r.bounds.top < paragraph.bounds.top &&
                _horizontalOverlap(r.bounds, paragraph.bounds) >= .5,
          )
          .toList()
        ..sort((a, b) => a.bounds.top.compareTo(b.bounds.top));
  final headings = [heading];
  var parent = _sectionHeadingLabel(heading);
  for (final child in between) {
    final label = _sectionHeadingLabel(child);
    // The first opening paragraph may sit below an explicit descendant heading
    // (5 -> 5.1, II -> A). Preserve that hierarchy; a sibling or unknown heading
    // is a boundary, not content to omit while borrowing its paragraph.
    if (parent == null ||
        label == null ||
        child.bounds.bottom > paragraph.bounds.top + 2 ||
        !(label.startsWith('$parent.') ||
            (RegExp(r'^[IVXLCDM]+$').hasMatch(parent) && label == 'A'))) {
      return null;
    }
    headings.add(child);
    parent = label;
  }
  return headings;
}

_Candidate _sectionCandidate(
  _Identity identity,
  _Region paragraph,
  List<_Region> regions, {
  List<_Region> headings = const [],
}) {
  final inline = regions
      .where(
        (r) =>
            r.model.category == podoco.RegionCategory.formula &&
            r.model.displayKind == podoco.FormulaDisplayKind.inline &&
            _covers(paragraph.bounds.inflate(1), r.bounds, .95),
      )
      .toList();
  return _Candidate(
    identity,
    [
      ...headings.map((r) => r.contentBounds),
      _union([
        paragraph.contentBounds,
        ...inline.map((r) => r.bounds.expandToInclude(r.contentBounds)),
      ]),
    ],
    [
      ...headings.map((r) => r.model.id),
      paragraph.model.id,
      ...inline.map((r) => r.model.id),
    ],
  );
}

double _sectionFont(_Region r) {
  final heights = r.lines.map((l) => l.bounds.height).toList()..sort();
  return heights[heights.length ~/ 2];
}

ResolvedLinkTarget _resolveSection(
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
  final candidates = <({_Region paragraph, _Candidate target})>[];
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
                  _sectionText(r) &&
                  r.bounds.top >= heading.bounds.bottom - 2 &&
                  r.bounds.top - heading.bounds.bottom <= 50 &&
                  ((r.bounds.left - heading.bounds.left).abs() <=
                          math.max(14, heading.bounds.width * .15) ||
                      (_horizontalOverlap(r.bounds, heading.bounds) >= .8 &&
                          (r.bounds.center.dx - heading.bounds.center.dx)
                                  .abs() <=
                              math.max(14, r.bounds.width * .15))),
            )
            .toList()
          ..sort((a, b) => a.bounds.top.compareTo(b.bounds.top));
    if (paragraphs.isEmpty ||
        (paragraphs.length > 1 &&
            (paragraphs[1].bounds.top - paragraphs.first.bounds.top).abs() <
                3)) {
      continue;
    }
    final paragraph = paragraphs.first;
    final headings = _sectionOpeningHeadings(heading, paragraph, regions);
    if (headings == null) continue;
    final target = _sectionCandidate(
      identity,
      paragraph,
      regions,
      headings: headings,
    );
    if (destination.y != null &&
        (destination.y! < target.bounds.top - 96 ||
            destination.y! > target.bounds.bottom + 96)) {
      continue;
    }
    if (!candidates.any(
      (c) =>
          _covers(c.target.bounds, target.bounds, .9) &&
          _covers(target.bounds, c.target.bounds, .9),
    )) {
      candidates.add((paragraph: paragraph, target: target));
    }
  }
  if (candidates.length != 1) {
    return miss(candidates.isEmpty ? 'noCompleteMatch' : 'competingMatches');
  }
  final opening = candidates.single, paragraph = opening.paragraph;
  final firstParts = _safeParts(
    opening.target.parts,
    opening.target.ids,
    regions,
    destination.pageSize,
  );
  if (firstParts == null) return miss('regionsContainNeighbor');
  final parts = [
    for (final b in firstParts) (page: destination.page, bounds: b),
  ];
  if (!_sectionTerminal(paragraph)) {
    // Only an identified, unfinished opening block at the end of its column
    // justifies reading the next page. Prose/equations below it or in a later
    // column are a boundary; never skip intervening text to find a continuation.
    if (paragraph.bounds.bottom < destination.pageSize.height * .78 ||
        regions.any(
          (r) =>
              r.model.id != paragraph.model.id &&
              (_sectionText(r) ||
                  r.model.category == podoco.RegionCategory.heading ||
                  (r.model.category == podoco.RegionCategory.formula &&
                      r.model.displayKind !=
                          podoco.FormulaDisplayKind.inline)) &&
              ((r.bounds.top >= paragraph.bounds.bottom &&
                      _horizontalOverlap(r.bounds, paragraph.bounds) >= .5) ||
                  r.bounds.left >= paragraph.bounds.right - 2),
        )) {
      return miss('uncertainSectionBoundary');
    }
    if (followingText == null || followingLayout == null) {
      return miss(
        'sectionNeedsContinuation',
        continuation: destination.page + 1,
      );
    }
    if (followingText.snapshot.page != destination.page + 1 ||
        followingLayout.page.page.key.pageIndex != destination.page) {
      return miss('invalidContinuationPage');
    }
    usedEvidence = (evidence, followingLayout.identity);
    final space = followingLayout.page.page.space;
    final nextSize = Size(space.width, space.height);
    final next = followingLayout.page.regions
        .map((r) => _Region(r, followingText))
        .toList();
    final body = next
        .where(
          (r) =>
              _sectionText(r) &&
              r.bounds.top <= nextSize.height * .45 &&
              !next.any(
                (v) =>
                    (v.model.category == podoco.RegionCategory.figure ||
                        v.model.category == podoco.RegionCategory.table ||
                        v.model.category == podoco.RegionCategory.caption) &&
                    _covers(v.bounds, r.bounds, .9),
              ),
        )
        .toList();
    if (body.isEmpty) return miss('missingSectionContinuation');
    // Start in the first body column, allowing a floating figure/table above it.
    final left = body.map((r) => r.bounds.left).reduce(math.min);
    body.removeWhere(
      (r) => r.bounds.left > left + math.max(18, nextSize.width * .05),
    );
    body.sort((a, b) => a.bounds.top.compareTo(b.bounds.top));
    final continuation = body.first;
    if (next.any(
          (r) =>
              r.model.category == podoco.RegionCategory.heading &&
              r.bounds.top < continuation.bounds.top &&
              _horizontalOverlap(r.bounds, continuation.bounds) >= .5,
        ) ||
        (body.length > 1 &&
            (body[1].bounds.top - continuation.bounds.top).abs() < 3) ||
        !RegExp(r'^\p{Ll}', unicode: true).hasMatch(continuation.text) ||
        !_sectionTerminal(continuation) ||
        continuation.bounds.bottom > nextSize.height - 16) {
      return miss('incompleteSectionContinuation');
    }
    final fontRatio = _sectionFont(continuation) / _sectionFont(paragraph);
    final widthRatio = continuation.bounds.width / paragraph.bounds.width;
    if (fontRatio < .75 ||
        fontRatio > 1.35 ||
        widthRatio < .45 ||
        widthRatio > 2.2) {
      return miss('sectionContinuationGeometryMismatch');
    }
    final target = _sectionCandidate(identity, continuation, next);
    final nextParts = _safeParts(target.parts, target.ids, next, nextSize);
    if (nextParts == null) return miss('sectionContinuationContainsNeighbor');
    parts.addAll([
      for (final b in nextParts) (page: destination.page + 1, bounds: b),
    ]);
  } else if (paragraph.bounds.bottom > destination.pageSize.height - 16) {
    return miss('uncertainSectionBoundary');
  }
  if (parts.length > 4) return miss('sectionPartLimit');
  return ResolvedLinkTarget(
    tier: LinkTargetTier.matchedIdentity,
    kind: identity.kind,
    label: identity.label,
    reason: 'matchedCompleteSection',
    evidenceIdentity: usedEvidence,
    parts: parts,
  );
}
