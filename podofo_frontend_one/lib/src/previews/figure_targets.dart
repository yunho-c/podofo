part of 'link_target_resolver.dart';

bool _numberedCaption(_Region r) => RegExp(
  r'^(?:Figure|Fig\.?|Table)\s+(?:\d+[a-z]?|[IVXLCDM]+)\b',
  caseSensitive: false,
).hasMatch(r.text);

bool _panelCaption(_Region r) =>
    (r.model.category == podoco.RegionCategory.caption ||
        (r.model.category == podoco.RegionCategory.text &&
            r.model.nativeSubtype == 'vision_footnote')) &&
    RegExp(r'^\(?[a-z]\)\s*', caseSensitive: false).hasMatch(r.text);

/// A panel-qualified link may name the parent figure only when that figure's
/// own caption or grouped labels explicitly identify the requested panel.
bool _hasFigurePanel(_Region caption, List<_Region> components, String panel) =>
    RegExp(
      '(?:^|\\s)\\($panel\\)(?=\\s|[,.;:]|\$)',
      caseSensitive: false,
    ).hasMatch(caption.text) ||
    components.any(
      (r) =>
          _panelCaption(r) &&
          RegExp('^\\(?$panel\\)', caseSensitive: false).hasMatch(r.text),
    );

/// A panel label is part of its figure, not a competing numbered caption.
/// Follow adjacent rows/columns so accepting a nearby row cannot silently omit
/// the other panels. The eventual crop still obeys the four-part render bound.
List<_Region>? _figureComponents(
  _Region caption,
  List<_Region> regions,
  LinkTargetKind kind,
) {
  final type = kind == LinkTargetKind.figure
      ? podoco.RegionCategory.figure
      : podoco.RegionCategory.table;
  final competing = regions.where(
    (r) =>
        r.model.category == podoco.RegionCategory.caption &&
        r.model.id != caption.model.id &&
        _numberedCaption(r),
  );
  bool belongs(_Region visual) =>
      _captionOverlap(visual.bounds, caption) >= .5 &&
      !competing.any(
        (other) =>
            (_captionOverlap(visual.bounds, other) >= .5 &&
                _captionGap(visual.bounds, other) + 3 <
                    _captionGap(visual.bounds, caption)) ||
            _captionBetween(other.bounds, visual.bounds, caption),
      );
  bool clear(_Region a, _Region b) => !regions.any(
    (r) =>
        r.model.id != caption.model.id &&
        (r.model.category == podoco.RegionCategory.text ||
            r.model.category == podoco.RegionCategory.heading ||
            r.model.category == podoco.RegionCategory.caption) &&
        !_panelCaption(r) &&
        !_covers(a.bounds, r.bounds, .9) &&
        !_covers(b.bounds, r.bounds, .9) &&
        _captionBetween(r.bounds, a.bounds, b),
  );
  final visuals = regions.where((r) => r.model.category == type).toList()
    ..sort((a, b) => _area(b.bounds).compareTo(_area(a.bounds)));
  final distinct = <_Region>[];
  for (final visual in visuals) {
    if (!distinct.any((p) => _covers(p.bounds, visual.bounds, .94))) {
      distinct.add(visual);
    }
  }
  final group = distinct
      .where(
        (r) =>
            belongs(r) &&
            _captionGap(r.bounds, caption) <= 80 &&
            clear(r, caption),
      )
      .toList();
  if (group.isEmpty) return null;
  double side(_Region r) => _sideways(caption)
      ? (r.bounds.center.dx - caption.bounds.center.dx).sign
      : (r.bounds.center.dy - caption.bounds.center.dy).sign;
  final direction = side(group.first);
  if (group.any((r) => side(r) != direction)) return null;
  var growing = true;
  while (growing) {
    growing = false;
    for (final r in distinct) {
      if (group.contains(r) || side(r) != direction || !belongs(r)) continue;
      if (group.any(
        (member) =>
            ((_horizontalOverlap(r.bounds, member.bounds) >= .6 &&
                    _verticalGap(r.bounds, member.bounds) <= 48) ||
                (_verticalOverlap(r.bounds, member.bounds) >= .6 &&
                    _horizontalGap(r.bounds, member.bounds) <= 48)) &&
            clear(r, member),
      )) {
        group.add(r);
        growing = true;
      }
    }
    if (group.length > 8) return null;
  }
  final envelope = _union([...group.map((r) => r.bounds), caption.bounds]);
  final labels = regions.where(
    (r) => _panelCaption(r) && _covers(envelope.inflate(2), r.bounds, .95),
  );
  return [...group, ...labels, caption]
    ..sort((a, b) => _readingCompare(a.bounds, b.bounds));
}
