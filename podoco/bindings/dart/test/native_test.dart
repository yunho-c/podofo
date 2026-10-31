import 'dart:io';

import 'package:podoco/podoco.dart';
import 'package:test/test.dart';

void main() {
  test('loads the Rust library through the native asset hook', () {
    expect(nativeAbiVersion, supportedAbiVersion);
    expect(
      nativeVersion,
      Platform.environment['PODOCO_EXPECTED_VERSION'] ?? '0.1.0',
    );
  });
}
