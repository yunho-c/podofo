import 'dart:convert';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:podoco/podoco.dart' as podoco;
import 'package:podofo_one/src/analysis/analysis_snapshot.dart';
import 'package:podofo_one/src/analysis/preview_layout_repository.dart';
import 'package:podofo_one/src/narration/source_map.dart';
import 'package:podofo_one/src/previews/link_target.dart';
import 'package:podofo_one/src/previews/link_target_resolver.dart';
import 'package:podofo_one/src/previews/preview_text.dart';

import 'fixtures/analysis_fixture.dart';

void main() {
  test('one linked list member resolves without accepting a multi-number annotation', () {
    final fixture = _references([
      '[13] Rivera. First.',
      '[19] Sato. Second.',
      '[25] Morris. Third.',
    ]);
    for (final c in [
      ('[13,', '', ' 19, 25]', '13'),
      ('19,', 'See [13, ', ' 25].', '19'),
      ('25]', 'See [13, 19, ', '.', '25'),
      ('19', 'See [13, ', ', 25].', '19'),
      ('19,', 'See [13, ', '20, 29–32, 34-37].', '19'),
    ]) {
      final target = fixture.resolve(c.$1, before: c.$2, after: c.$3);
      expect(
        target.tier,
        LinkTargetTier.matchedIdentity,
        reason: target.reason,
      );
      expect(target.label, 'Reference [${c.$4}]');
    }
    for (final c in [
      ('[13, 19]', '', ''),
      ('19,', 'See 13, ', '25.'),
      ('19,', 'See [13-', '25]'),
      ('19,', 'See [13, ', 'twenty-five]'),
      ('19,', 'See [13, ', '25'),
      ('19–25', 'See [13, ', '].'),
    ]) {
      expect(
        fixture.resolve(c.$1, before: c.$2, after: c.$3).tier,
        LinkTargetTier.unresolved,
      );
    }
  });
  test(
    'author-only and subsequent-year links retain the same first author',
    () {
      final fixture = _references([
        'Alice Rivera, Ben Sato. First. 2023.',
        'Alice Rivera, Ben Sato. Second. 2024.',
        'Ben Sato, Alice Rivera. Third. 2024.',
      ]);
      final first = fixture.resolve('[Rivera et al.,', after: ' 2023, 2024].');
      expect(first.label, 'Rivera (2023)');
      final second = fixture.resolve('2024,', before: '[Rivera et al., 2023, ');
      expect(second.label, 'Rivera (2024)');
      expect(second.parts.single.bounds.contains(const Offset(25, 58)), true);
      expect(second.parts.single.bounds.contains(const Offset(25, 72)), false);
      expect(
        fixture.resolve('2024,', before: '[Rivera et al., 2023; ').tier,
        LinkTargetTier.unresolved,
      );
      expect(
        fixture.resolve('2023, 2024', before: '[Rivera et al., ').tier,
        LinkTargetTier.unresolved,
      );
    },
  );
  test('ditto authors inherit only author identity, keeping years and crops separate', () {
    final fixture = _references([
      'Rivera, Alice (2022). First.',
      '– (2023). Second.',
      '— (2024). Third.',
      'Sato, Ben (2025). Next.',
    ]);
    for (final year in ['2022', '2023', '2024']) {
      final result = fixture.resolve(
        '$year;',
        before: 'See Rivera et\r\nal., ',
      );
      expect(result.tier, LinkTargetTier.matchedIdentity);
      expect(result.label, 'Rivera ($year)');
      final row = int.parse(year) - 2022;
      expect(
        result.parts.single.bounds.contains(Offset(25, 44 + row * 14)),
        true,
      );
      for (var other = 0; other < 4; other++) {
        if (other != row) {
          expect(
            result.parts.single.bounds.contains(Offset(25, 44 + other * 14)),
            false,
          );
        }
      }
    }
    for (final selected in ['2024a;', '2026;', '2022; Rivera 2024']) {
      expect(
        fixture.resolve(selected, before: 'See Rivera et al., ').tier,
        LinkTargetTier.unresolved,
      );
    }
    expect(
      fixture.resolve('2024;', before: 'See Sato et al., ').tier,
      LinkTargetTier.unresolved,
    );
  });
  test('an orphan ditto entry or a distant author cannot supply identity', () {
    final orphan = _references(['— (2024). Third.', 'Sato, Ben (2025). Next.']);
    expect(
      orphan.resolve('2024;', before: 'Rivera et al., ').tier,
      LinkTargetTier.unresolved,
    );
    final distant = _references([
      'Rivera, Alice (2022). First.',
      '— (2024). Third.',
      'Sato, Ben (2025). Next.',
    ], gap: 40);
    expect(
      distant.resolve('2024;', before: 'Rivera et al., ').tier,
      LinkTargetTier.unresolved,
    );
  });
}

_Fixture _references(List<String> lines, {double gap = 14}) {
  final text = StringBuffer(),
      boxes = <Rect>[],
      regions = <Map<String, Object?>>[];
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i], y = 40 + i * gap;
    text.write('$line\n');
    for (var char = 0; char < line.length; char++) {
      boxes.add(Rect.fromLTWH(20 + char * 3, y, 3, 8));
    }
    boxes.add(Rect.zero);
    regions.add({
      'id': i,
      'model_class_id': 0,
      'model_label': 'reference',
      'category': 'text',
      'native_subtype': 'reference_content',
      'bounds': [19, y - 1, 21 + line.length * 3, y + 9],
      'display_kind': null,
      'polygon': null,
      'score': 1.0,
      'diagnostics': [],
    });
  }
  final json = jsonDecode(
    jsonEncode(
      analysisFixture(podoco.DocumentRef('reference', 'fixture')).toJson(),
    ),
  ) as Map<String, dynamic>;
  final page = (json['payload'] as Map)['page'] as Map;
  page['regions'] = regions;
  final snapshot = AnalysisPageSnapshot.fromUpdate(
    podoco.AnalysisUpdate.fromJson(json),
  );
  return _Fixture(
    PreviewTextPage(
      PdfTextSnapshot(
        page: 1,
        text: text.toString(),
        boxes: [
          for (final b in boxes)
            PdfRect(b.left, 360 - b.top, b.right, 360 - b.bottom),
        ],
      ),
      boxes,
    ),
    PreviewLayoutEvidence(snapshot),
  );
}

class _Fixture {
  _Fixture(this.text, this.layout);
  final PreviewTextPage text;
  final PreviewLayoutEvidence layout;
  ResolvedLinkTarget resolve(
    String selected, {
    String before = '',
    String after = '',
  }) => const LinkTargetResolver().resolve(
    const PreviewDestination(page: 1, pageSize: Size(260, 360)),
    text: text,
    layout: layout,
    source: LinkSourceText(
      [PreviewTextSpan(0, selected.length, selected, [])],
      before,
      after,
      false,
    ),
  );
}
