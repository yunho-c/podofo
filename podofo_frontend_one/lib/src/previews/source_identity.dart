part of 'link_target_resolver.dart';

const _targetLabel =
    r'(?:\d+(?:\.\d+)*[a-z]?|[A-Z](?:\.\d+)+|[IVXLCDM]+|[A-Z])';
const _targetPrefix =
    r'(Figures?|Figs?\.?|Tables?|Equations?|Eqs?\.?|Sections?|Secs?\.?|Appendix|Appendices|App\.?)';

String _canonicalLabel(String label) => RegExp(r'^[A-Za-z]').hasMatch(label)
    ? label.toUpperCase()
    : label.toLowerCase();

LinkTargetKind _namedKind(String prefix) {
  prefix = prefix.toLowerCase();
  return prefix.startsWith('fig')
      ? LinkTargetKind.figure
      : prefix.startsWith('tab')
      ? LinkTargetKind.table
      : prefix.startsWith('eq')
      ? LinkTargetKind.equation
      : LinkTargetKind.section;
}

/// Only one number may belong to this annotation. Neighboring annotations in a
/// well-formed bracketed list provide context, not additional selected numbers.
String? _listCitation(String selected, String before, String after) {
  final number = RegExp(r'^\[?(\d+)[,\]]?$').firstMatch(selected);
  if (number == null) return null;
  final joined = '$before$selected$after';
  final start = joined.lastIndexOf('[', before.length);
  if (start < 0 || before.length - start > 80) return null;
  final end = joined.indexOf(']', before.length + selected.length - 1);
  if (end < 0 || end - before.length - selected.length > 80) return null;
  final numberStart = before.length + (selected.startsWith('[') ? 1 : 0);
  final numberEnd = numberStart + number.group(1)!.length;
  if (!RegExp(r'[\[,]\s*$').hasMatch(joined.substring(start, numberStart)) ||
      !RegExp(r'^\s*[,\]]').hasMatch(joined.substring(numberEnd, end + 1))) {
    return null;
  }
  // Other list members may be ranges. A selected range or either endpoint of
  // one still fails the single-member boundary checks above.
  if (!RegExp(
    r'^\[\s*\d+(?:\s*[-–]\s*\d+)?(?:\s*,\s*\d+(?:\s*[-–]\s*\d+)?)*\s*\]$',
  ).hasMatch(joined.substring(start, end + 1))) {
    return null;
  }
  return number.group(1);
}

_Identity? _sourceIdentity(LinkSourceText source) {
  var selected = _clean(source.spans.map((s) => s.text).join(' '));
  // Some PDFs put the abbreviation's period inside the link rectangle. Carry
  // only its immediately preceding abbreviation into the named-label parser;
  // a leading decimal point without that evidence remains ambiguous.
  if (selected.startsWith('.')) {
    final prefix = RegExp(
      r'\b(Figs?|Eqs?|Secs?|App)$',
      caseSensitive: false,
    ).firstMatch(_clean(source.before));
    if (prefix != null) selected = '${prefix.group(1)}$selected';
  }
  final direct = RegExp(r'^(?:Citation\s*)?\[(\d+)\]$').firstMatch(selected);
  if (direct != null) {
    return _Identity(LinkTargetKind.citation, direct.group(1)!);
  }
  final citation = _listCitation(selected, source.before, source.after);
  if (citation != null) return _Identity(LinkTargetKind.citation, citation);

  // Parenthesized figure panels may straddle the annotation boundary: the link
  // selects "2(" and the immediately following text supplies "a)". Preserve the
  // panel identity so the resolver still requires proof in the parent figure.
  final panel = RegExp(
    r'^(?:(Figures?|Figs?\.?)\s+)?(\d+)\((?:([a-z])\)[,.]?)?$',
    caseSensitive: false,
  ).firstMatch(selected);
  if (panel != null) {
    if (panel.group(1) == null &&
        !RegExp(
          r'\b(?:Figures?|Figs?\.?)\s*$',
          caseSensitive: false,
        ).hasMatch(_clean(source.before))) {
      return null;
    }
    final suffix =
        panel.group(3) ??
        RegExp(
          r'^\s*([a-z])\)(?=\s|[,.;:]|$)',
          caseSensitive: false,
        ).firstMatch(source.after)?.group(1);
    if (suffix == null) return null;
    return _Identity(
      LinkTargetKind.figure,
      '${panel.group(2)}${suffix.toLowerCase()}',
    );
  }

  // IEEE-style subsection links print the parent and child together (II-C),
  // while the target heading may print only C. Keep the full identity for the
  // resolver to check against parent-heading or precise destination evidence.
  final compound = RegExp(
    r'^(?:(Sections?|Secs?\.?)\s+)?\(?([IVXLCDM]+[-–][A-Z])[),.]*$',
    caseSensitive: false,
  ).firstMatch(selected);
  if (compound != null &&
      (compound.group(1) != null ||
          RegExp(
            r'\b(?:Sections?|Secs?\.?)\s*$',
            caseSensitive: false,
          ).hasMatch(_clean(source.before)))) {
    return _Identity(
      LinkTargetKind.section,
      compound.group(2)!.replaceAll('–', '-').toUpperCase(),
    );
  }

  final named = RegExp(
    '\\b$_targetPrefix\\s*\\(?\\s*($_targetLabel)\\b',
    caseSensitive: false,
  );
  final names = named.allMatches(selected).toList();
  if (names.length > 1) return null;
  if (names.isNotEmpty) {
    // Includes Roman and appendix labels so "Sections II and III" is just as
    // ambiguous as "Figures 2 and 3" under a single annotation.
    final match = names.single;
    if (RegExp(
      '\\b$_targetLabel\\b',
      caseSensitive: false,
    ).hasMatch(selected.replaceRange(match.start, match.end, ' '))) {
      return null;
    }
    return _Identity(
      _namedKind(match.group(1)!),
      _canonicalLabel(match.group(2)!),
    );
  }
  final bare = RegExp(
    '^\\(?($_targetLabel)[),.]*\$',
    caseSensitive: false,
  ).firstMatch(selected);
  if (bare != null) {
    // A link may contain just the second number in "Eqs. 1, 2". Only a
    // contiguous comma-separated label list may carry its prefix forward.
    final before = _clean(
      source.before.substring(math.max(0, source.before.length - 80)),
    );
    final prefix = RegExp(
      '\\b$_targetPrefix\\s*\\(?\\s*(?:$_targetLabel\\)?\\s*,\\s*)*\$',
      caseSensitive: false,
    ).firstMatch(before);
    if (prefix != null) {
      return _Identity(
        _namedKind(prefix.group(1)!),
        _canonicalLabel(bare.group(1)!),
      );
    }
  }
  final equation = RegExp(r'^\((\d+[a-z]?)\)$').firstMatch(selected);
  if (equation != null) {
    return _Identity(LinkTargetKind.equation, equation.group(1)!);
  }

  // Bibliography links can include list punctuation or only the second year
  // belonging to the immediately preceding author. Never borrow an older year.
  if (RegExp(r'\b(?:19|20)\d{2}[a-z]?\b').allMatches(selected).length > 1) {
    return null;
  }
  final authorSelected = selected.replaceFirst(RegExp(r'[;,]$'), '');
  final before = _clean(
    source.before.substring(math.max(0, source.before.length - 80)),
  ).replaceFirst(RegExp(r'(?:\b(?:19|20)\d{2}[a-z]?\s*,\s*)+$'), '');
  final authorText =
      RegExp(r'^\(?(?:19|20)\d{2}[a-z]?\)?$').hasMatch(authorSelected)
      ? '$before $authorSelected'
      : authorSelected;
  final author = RegExp(
    r'(?:^|\s|[\[(])([\p{Lu}][\p{L}\-\x27’]+)(?:\s+(?:et\s+al\.?|and\s+[\p{Lu}][\p{L}\-\x27’]+))?[,\s]*\(?\s*((?:19|20)\d{2}[a-z]?)\)?$',
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
    r'^[\[(]?([\p{Lu}][\p{L}\-\x27’]+)\s+(?:et\s+al\.?|and\s+[\p{Lu}][\p{L}\-\x27’]+)[,\s]*$',
    unicode: true,
  ).firstMatch(selected);
  if (authorOnly != null) {
    final year = RegExp(
      r'^\s*[\[(]?((?:19|20)\d{2}[a-z]?)\b',
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
