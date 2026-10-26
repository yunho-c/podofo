import 'dart:convert';
import 'dart:io';

import 'package:podoco/podoco.dart';
import 'package:test/test.dart';

void main() {
  final fixtures = (jsonDecode(
    File('test/fixtures/updates.json').readAsStringSync(),
  ) as List).cast<Map<String, dynamic>>();
  Map<String, Object?> fresh(int i) =>
      Map<String, Object?>.from(jsonDecode(jsonEncode(fixtures[i])) as Map);
  test(
    'all Rust v0 semantic fixtures decode and retain immutable owned envelopes',
    () {
      for (final fixture in fixtures) {
        final result = AnalysisUpdate.fromJson(fixture);
        expect(result.toJson(), fixture);
        expect(() => result.toJson()['sequence'] = 999, throwsUnsupportedError);
        expect(
          () => (result.toJson()['document'] as Map)['id'] = 'changed',
          throwsUnsupportedError,
        );
        if (result is PageLayoutReady) {
          expect(() => result.page.regions.clear(), throwsUnsupportedError);
          expect(
            () => result.page.provenance.pipeline.models.clear(),
            throwsUnsupportedError,
          );
        }
      }
    },
  );
  test('schema and required variants fail while additive fields survive', () {
    final version = fresh(0)..['schema_version'] = 99;
    expect(() => AnalysisUpdate.fromJson(version), throwsFormatException);
    final variant = fresh(0);
    (variant['payload'] as Map)['type'] = 'future_required_update';
    expect(() => AnalysisUpdate.fromJson(variant), throwsFormatException);
    final added = fresh(0)
      ..['optional_field'] = {
        'future': [1, 2],
      };
    final result = AnalysisUpdate.fromJson(added);
    expect(result.toJson()['optional_field'], {
      'future': [1, 2],
    });
  });
  test('invalid page identity, region duplication and score are rejected', () {
    final identity = fresh(0);
    (identity['document'] as Map)['revision'] = 'wrong';
    expect(() => AnalysisUpdate.fromJson(identity), throwsFormatException);
    final duplicate = fresh(0);
    final page = (duplicate['payload'] as Map)['page'] as Map;
    final regions = page['regions'] as List;
    regions.add(regions.first);
    expect(() => AnalysisUpdate.fromJson(duplicate), throwsFormatException);
    for (final polygon in [
      [
        [0, 0],
        [1, 1],
        [2, 2],
      ],
      [
        [0, 0, 1],
        [1, 0],
        [1, 1],
      ],
      [
        [0, 0],
        [1, 1],
      ],
    ]) {
      final invalid = fresh(0);
      (((invalid['payload'] as Map)['page'] as Map)['regions'] as List)
              .first['polygon'] =
          polygon;
      expect(() => AnalysisUpdate.fromJson(invalid), throwsFormatException);
    }
    expect(() => Affine([1e-310, 0, 0, 1, 0, 0]), throwsArgumentError);
    final oversized = fresh(0);
    (((oversized['payload'] as Map)['page'] as Map)['regions'] as List)
            .first['model_class_id'] =
        0x100000000;
    expect(() => AnalysisUpdate.fromJson(oversized), throwsFormatException);
    final score = fresh(0);
    (((score['payload'] as Map)['page'] as Map)['regions'] as List)
            .first['score'] =
        2;
    expect(() => AnalysisUpdate.fromJson(score), throwsFormatException);
  });
}
