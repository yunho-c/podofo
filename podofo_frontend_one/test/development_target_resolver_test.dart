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
  test('a two-row figure retains every panel and its panel captions', () {
    final regions = [
      _r('figure', [310, 60, 420, 140], 'Panel one'),
      _r('figure', [440, 60, 550, 140], 'Panel two'),
      _r('caption', [390, 145, 480, 155], '(a) Upper row'),
      _r('figure', [310, 165, 420, 245], 'Panel three'),
      _r('figure', [440, 165, 550, 245], 'Panel four'),
      _r('caption', [390, 250, 480, 260], '(b) Lower row'),
      _r('caption', [310, 270, 550, 300], 'Figure 3. Four panels.'),
      _r('text', [310, 330, 550, 380], 'Unrelated following paragraph.'),
    ];
    final target = _resolve(regions, 'Figure 3');
    expect(target.tier, LinkTargetTier.matchedIdentity, reason: target.reason);
    for (final r in regions.take(7)) {
      expect(target.parts.any((p) => p.bounds.contains(_rect(r).center)), true);
    }
    expect(
      target.parts.any((p) => p.bounds.overlaps(_rect(regions.last))),
      false,
    );
    expect(target.parts.length, lessThanOrEqualTo(4));
  });

  test(
    'panel labels do not steal a pair of images from their main caption',
    () {
      final regions = [
        _r('figure', [100, 60, 270, 175], 'Original'),
        _r('figure', [280, 60, 450, 175], 'Decoded'),
        _r('caption', [150, 180, 230, 190], '(a) Original'),
        _r('caption', [330, 180, 410, 190], '(b) Decoded'),
        _r('caption', [90, 205, 470, 230], 'Figure 1. Comparison.'),
        _r('caption', [90, 245, 470, 270], 'Table 1. Unrelated table.'),
        _r('table', [90, 280, 470, 330], 'Other results'),
      ];
      final target = _resolve(regions, 'Figure 1');
      expect(
        target.tier,
        LinkTargetTier.matchedIdentity,
        reason: target.reason,
      );
      for (final r in regions.take(5)) {
        expect(
          target.parts.any((p) => p.bounds.contains(_rect(r).center)),
          true,
        );
      }
      for (final r in regions.skip(5)) {
        expect(target.parts.any((p) => p.bounds.overlaps(_rect(r))), false);
      }
    },
  );

  test('another numbered caption stops growth into a different figure', () {
    final regions = [
      _r('figure', [310, 60, 550, 140], 'Another figure'),
      _r('caption', [310, 145, 550, 155], 'Figure 2. Other.'),
      _r('figure', [310, 185, 550, 250], 'Target'),
      _r('caption', [310, 270, 550, 300], 'Figure 3. Target.'),
    ];
    final target = _resolve(regions, 'Figure 3');
    expect(target.tier, LinkTargetTier.matchedIdentity, reason: target.reason);
    expect(
      target.parts.any((p) => p.bounds.overlaps(_rect(regions.first))),
      false,
    );
  });
}

Map<String, Object?> _r(String category, List<double> bounds, String text) => {
  'category': category,
  'bounds': bounds,
  'text': text,
};

Rect _rect(Map<String, Object?> region) {
  final b = region['bounds'] as List<double>;
  return Rect.fromLTRB(b[0], b[1], b[2], b[3]);
}

ResolvedLinkTarget _resolve(
  List<Map<String, Object?>> regions,
  String selected, {
  String before = '',
  String after = '',
}) {
  final content = StringBuffer(), boxes = <Rect>[];
  for (final r in regions) {
    final rect = _rect(r), text = r['text'] as String;
    content.writeln(text);
    for (var i = 0; i < text.length; i++) {
      boxes.add(Rect.fromLTWH(rect.left + i * 3 + 1, rect.top + 1, 3, 7));
    }
    boxes.add(Rect.zero);
  }
  final json = jsonDecode(
    jsonEncode(
      analysisFixture(podoco.DocumentRef('grouping', 'fixture')).toJson(),
    ),
  );
  final page = json['payload']['page'];
  page['page']['space'] = [600, 800];
  page['regions'] = [
    for (var i = 0; i < regions.length; i++)
      {
        'id': i,
        'model_class_id': 0,
        'model_label': 'hand-annotated-fixture',
        'category': regions[i]['category'],
        'native_subtype': null,
        'bounds': regions[i]['bounds'],
        'display_kind': regions[i]['category'] == 'formula'
            ? 'displayed'
            : null,
        'polygon': null,
        'score': 1.0,
        'diagnostics': [],
      },
  ];
  return const LinkTargetResolver().resolve(
    const PreviewDestination(page: 1, pageSize: Size(600, 800)),
    source: LinkSourceText(
      [PreviewTextSpan(0, selected.length, selected, [])],
      before,
      after,
      false,
    ),
    text: PreviewTextPage(
      PdfTextSnapshot(
        page: 1,
        text: content.toString(),
        boxes: [
          for (final b in boxes)
            PdfRect(b.left, 800 - b.top, b.right, 800 - b.bottom),
        ],
      ),
      boxes,
    ),
    layout: PreviewLayoutEvidence(
      AnalysisPageSnapshot.fromUpdate(
        podoco.AnalysisUpdate.fromJson(Map<String, Object?>.from(json)),
      ),
    ),
  );
}
