import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import '../tool/rendering_quality/measure.dart';

void main() {
  test(
    'RGB metrics have known units and no edge ratio for a flat reference',
    () {
      final metrics = measure(
        Uint8List.fromList([0, 0, 0, 255]),
        Uint8List.fromList([3, 0, 0, 255]),
        1,
        1,
        (left: 0, top: 0, right: 1, bottom: 1),
      );
      expect(metrics['mae_8bit'], 1);
      expect(metrics['rmse_8bit'], math.sqrt(3));
      expect(metrics['different_fraction_gt_2'], 1);
      expect(metrics['edge_energy_ratio'], isNull);
      expect(metrics['reference_ink_fraction'], 1);
    },
  );

  test('mask excludes changed pixels outside the scoring region', () {
    final reference = Uint8List.fromList([255, 255, 255, 255, 0, 0, 0, 255]);
    final candidate = Uint8List.fromList([0, 0, 0, 255, 0, 0, 0, 255]);
    final metrics = measure(reference, candidate, 2, 1, (
      left: 1,
      top: 0,
      right: 2,
      bottom: 1,
    ));
    expect(metrics['pixels'], 1);
    expect(metrics['mae_8bit'], 0);
    expect(metrics['different_fraction_gt_2'], 0);
  });

  test('mismatched buffers and invalid masks fail explicitly', () {
    final pixel = Uint8List(4);
    expect(
      () => measure(pixel, Uint8List(8), 1, 1, (
        left: 0,
        top: 0,
        right: 1,
        bottom: 1,
      )),
      throwsArgumentError,
    );
    for (final rect in [
      (left: 0, top: 0, right: 0, bottom: 1),
      (left: -1, top: 0, right: 1, bottom: 1),
      (left: 0, top: 0, right: 2, bottom: 1),
    ]) {
      expect(() => measure(pixel, pixel, 1, 1, rect), throwsArgumentError);
    }
  });

  test('controls detect blur, a one-pixel shift, and undersized rendering', () {
    final controls = calibration();
    expect(controls['passed'], isTrue);
    final identity = controls['identical'] as Map;
    expect(identity['mae_8bit'], 0);
    expect(identity['edge_energy_ratio'], 1);
    for (final name in ['blurred', 'shifted_1px', 'undersized']) {
      final score = controls[name] as Map;
      expect(score['mae_8bit'], greaterThan(1), reason: name);
      expect(score['different_fraction_gt_2'], greaterThan(.1), reason: name);
    }
  });
}
