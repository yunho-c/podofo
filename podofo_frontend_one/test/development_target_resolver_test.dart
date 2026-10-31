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
  test('section openings retain intervening descendant headings', () {
    for (final labels in [('5', '5.1'), ('II', 'A')]) {
      final target = _resolve([
        _r('heading', [140, 100, 220, 115], '${labels.$1}. Results'),
        _r('heading', [100, 125, 300, 140], '${labels.$2}. Overview'),
        _r('text', [100, 150, 300, 180], 'The complete opening paragraph.'),
      ], 'Section ${labels.$1}');
      expect(
        target.tier,
        LinkTargetTier.matchedIdentity,
        reason: target.reason,
      );
      expect(
        target.parts.any((p) => p.bounds.contains(const Offset(105, 129))),
        true,
        reason: 'The child heading belongs between the parent and paragraph',
      );
    }
  });
  test('a sibling heading prevents borrowing its opening paragraph', () {
    final target = _resolve([
      _r('heading', [140, 100, 220, 115], '5. Results'),
      _r('heading', [100, 125, 300, 140], '6. Discussion'),
      _r('text', [
        100,
        150,
        300,
        180,
      ], 'This paragraph belongs to section six.'),
    ], 'Section 5');
    expect(target.tier, LinkTargetTier.unresolved);
    expect(target.parts, isEmpty);
  });
  test(
    'equations aligned across columns retain their own number and formula',
    () {
      final regions = [
        _r('formula', [80, 100, 220, 120], 'a = b + c'),
        _r('formula_number', [240, 100, 255, 120], '(1)'),
        _r('formula', [340, 100, 420, 120], 'd = e + f'),
        _r('formula_number', [480, 100, 495, 120], '(2)'),
      ];
      for (final number in [1, 2]) {
        final target = _resolve(regions, '($number)');
        expect(
          target.tier,
          LinkTargetTier.matchedIdentity,
          reason: target.reason,
        );
        expect(
          target.parts.any(
            (p) => p.bounds.contains(_rect(regions[(number - 1) * 2]).center),
          ),
          true,
        );
        expect(
          target.parts.any(
            (p) => p.bounds.overlaps(_rect(regions[(2 - number) * 2])),
          ),
          false,
        );
      }
      final tall = [...regions];
      tall[2] = _r('formula', [340, 90, 460, 180], 'd = e + f\n= g + h');
      tall[3] = _r('formula_number', [480, 160, 495, 180], '(2)');
      final target = _resolve(tall, '(1)');
      expect(
        target.tier,
        LinkTargetTier.matchedIdentity,
        reason: target.reason,
      );
      expect(target.parts.any((p) => p.bounds.overlaps(_rect(tall[2]))), false);
    },
  );
  test('centered headings retain a complete text block ending in a colon', () {
    final regions = [
      _r('heading', [160, 100, 240, 115], 'III. Method'),
      _r('text', [
        100,
        130,
        300,
        165,
      ], 'The first line introduces\nthe following expression:'),
      _r('formula', [140, 175, 240, 195], 'x = y + z'),
    ];
    final target = _resolve(regions, 'Section III');
    expect(target.tier, LinkTargetTier.matchedIdentity, reason: target.reason);
    expect(
      target.parts.any((p) => p.bounds.contains(const Offset(150, 149))),
      true,
    );
    expect(
      target.parts.any((p) => p.bounds.overlaps(_rect(regions.last))),
      false,
    );
  });
  test(
    'inline formula extent belongs to its paragraph and not the next one',
    () {
      final regions = [
        _r('heading', [100, 100, 300, 115], '2. Method'),
        _r('text', [
          100,
          130,
          300,
          170,
        ], 'An opening paragraph\ncontains inline mathematics.'),
        _r('formula', [140, 141, 210, 163], '', inline: true),
        _r('text', [100, 180, 300, 210], 'Unrelated following paragraph.'),
      ];
      final target = _resolve(regions, 'Section 2');
      expect(
        target.tier,
        LinkTargetTier.matchedIdentity,
        reason: target.reason,
      );
      expect(
        target.parts.any((p) => p.bounds.contains(const Offset(209, 162))),
        true,
      );
      expect(
        target.parts.any((p) => p.bounds.overlaps(_rect(regions.last))),
        false,
      );
    },
  );
  test('padding stops before an immediately following paragraph', () {
    final target = _resolve([
      _r('heading', [100, 100, 300, 115], '2. Method'),
      _r('text', [100, 130, 300, 139], 'Complete.'),
      _r('text', [100, 139.5, 300, 180], 'Next paragraph.'),
    ], 'Section 2');
    expect(target.tier, LinkTargetTier.matchedIdentity, reason: target.reason);
    expect(target.parts.last.bounds.bottom, lessThanOrEqualTo(139.5));
    expect(target.parts.last.bounds.contains(const Offset(105, 137)), true);
  });
  test(
    'section continuation is bounded and requires first-column evidence',
    () {
      final first = [
        _r('heading', [100, 700, 300, 715], '4. Method'),
        _r('text', [100, 735, 300, 785], 'An opening block continues with the'),
      ];
      final next = [
        _r('figure', [100, 50, 500, 160], 'Floating figure'),
        _r('caption', [100, 165, 500, 180], 'Figure 9. Other.'),
        _r('text', [100, 200, 500, 240], 'remaining words on the next page.'),
        _r('text', [100, 250, 500, 280], 'Another paragraph.'),
      ];
      final pending = _resolve(first, 'Section 4');
      expect(pending.continuationPage, 2);
      expect(pending.parts, isEmpty);
      final target = _resolve(first, 'Section 4', following: next);
      expect(
        target.tier,
        LinkTargetTier.matchedIdentity,
        reason: target.reason,
      );
      expect(target.parts.map((p) => p.page).toSet(), {1, 2});
      expect(target.parts.last.bounds.top, greaterThan(180));
      expect(target.parts.last.bounds.bottom, lessThan(250));
      expect(
        _resolve(first, 'Section 4', following: next, followingPage: 3).reason,
        'invalidContinuationPage',
      );
      final newSection = [
        _r('heading', [100, 185, 500, 195], '5. Next section'),
        ...next,
      ];
      expect(
        _resolve(first, 'Section 4', following: newSection).tier,
        LinkTargetTier.unresolved,
      );
      final unfinished = [...next]
        ..[2] = _r('text', [100, 200, 500, 240], 'still unfinished and');
      final rejected = _resolve(first, 'Section 4', following: unfinished);
      expect(rejected.tier, LinkTargetTier.unresolved);
      expect(rejected.continuationPage, isNull);
      expect(
        _resolve([
          ...first,
          _r('heading', [100, 787, 300, 798], '5. Next'),
        ], 'Section 4').continuationPage,
        isNull,
      );
      final laterColumn = _resolve(
        [
          ...first,
          _r('text', [
            330,
            100,
            550,
            180,
          ], 'Remaining text in the next column.'),
        ],
        'Section 4',
        following: next,
      );
      expect(laterColumn.tier, LinkTargetTier.unresolved);
      expect(laterColumn.continuationPage, isNull);
    },
  );
  test(
    'plural equation prefixes apply only to a single linked list member',
    () {
      final regions = [
        _r('formula', [100, 100, 220, 120], 'a = b + c'),
        _r('formula_number', [240, 100, 255, 120], '(1)'),
        _r('formula', [100, 160, 220, 180], 'd = e + f'),
        _r('formula_number', [240, 160, 255, 180], '(2)'),
      ];
      expect(_resolve(regions, '1,', before: 'Eqs. ').label, 'Equation (1)');
      expect(_resolve(regions, '2', before: 'Eqs. 1, ').label, 'Equation (2)');
      expect(
        _resolve(regions, '2', before: 'Eqs. 1, unrelated text ').tier,
        LinkTargetTier.unresolved,
      );
      expect(_resolve(regions, 'Eqs. 1, 2').tier, LinkTargetTier.unresolved);
    },
  );
  test(
    'Roman and appendix labels preserve explicit identity and ambiguity',
    () {
      final sections = [
        _r('heading', [100, 100, 300, 120], 'III. Methods'),
        _r('text', [100, 130, 300, 160], 'A complete opening paragraph.'),
        _r('heading', [100, 200, 300, 220], 'A.1 Appendix method'),
        _r('text', [100, 230, 300, 260], 'Another complete opening paragraph.'),
      ];
      expect(
        _resolve(sections, 'III', before: 'Section ').label,
        'Section III',
      );
      expect(
        _resolve(sections, 'A.1.', before: 'Appendix ').label,
        'Section A.1',
      );
      expect(
        _resolve(sections, 'Sections II and III').tier,
        LinkTargetTier.unresolved,
      );
      expect(
        _resolve(sections, 'Appendices A.1, A.2').tier,
        LinkTargetTier.unresolved,
      );
      final table = [
        _r('caption', [100, 100, 300, 120], 'TABLE I. Notations'),
        _r('table', [100, 130, 300, 200], 'All table rows'),
      ];
      expect(_resolve(table, 'I', before: 'Table ').label, 'Table I');
      expect(_resolve(table, 'I').tier, LinkTargetTier.unresolved);
    },
  );
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

Map<String, Object?> _r(
  String category,
  List<double> bounds,
  String text, {
  bool inline = false,
}) => {'category': category, 'bounds': bounds, 'text': text, 'inline': inline};

Rect _rect(Map<String, Object?> region) {
  final b = region['bounds'] as List<double>;
  return Rect.fromLTRB(b[0], b[1], b[2], b[3]);
}

ResolvedLinkTarget _resolve(
  List<Map<String, Object?>> regions,
  String selected, {
  String before = '',
  String after = '',
  List<Map<String, Object?>>? following,
  int followingPage = 2,
}) {
  final first = _page(regions);
  final next = following == null
      ? null
      : _page(following, number: followingPage);
  return const LinkTargetResolver().resolve(
    const PreviewDestination(page: 1, pageSize: Size(600, 800)),
    source: LinkSourceText(
      [PreviewTextSpan(0, selected.length, selected, [])],
      before,
      after,
      false,
    ),
    text: first.text,
    layout: first.layout,
    followingText: next?.text,
    followingLayout: next?.layout,
  );
}

({PreviewTextPage text, PreviewLayoutEvidence layout}) _page(
  List<Map<String, Object?>> regions, {
  int number = 1,
}) {
  final content = StringBuffer(), boxes = <Rect>[];
  for (final r in regions) {
    final rect = _rect(r), text = r['text'] as String;
    content.writeln(text);
    var column = 0, row = 0;
    for (var i = 0; i < text.length; i++) {
      if (text[i] == '\n') {
        boxes.add(Rect.zero);
        column = 0;
        row++;
      } else {
        boxes.add(
          Rect.fromLTWH(
            rect.left + column * 3 + 1,
            rect.top + row * 12 + 1,
            3,
            7,
          ),
        );
        column++;
      }
    }
    boxes.add(Rect.zero);
  }
  final json = jsonDecode(
    jsonEncode(
      analysisFixture(
        podoco.DocumentRef('grouping', 'fixture'),
        pageIndex: number - 1,
      ).toJson(),
    ),
  );
  final page = json['payload']['page'];
  page['page']['space'] = [600, 800];
  page['provenance']['image'] = {
    'width': 600,
    'height': 800,
    'row_stride': 2400,
    'format': 'bgra8',
    'alpha': 'opaque',
  };
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
            ? (regions[i]['inline'] == true ? 'inline' : 'displayed')
            : null,
        'polygon': null,
        'score': 1.0,
        'diagnostics': [],
      },
  ];
  page['formulas'] = [
    for (var i = 0; i < regions.length; i++)
      if (regions[i]['category'] == 'formula')
        {
          'region_id': i,
          'state': {'state': 'not_requested'},
        },
  ];
  return (
    text: PreviewTextPage(
      PdfTextSnapshot(
        page: number,
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
