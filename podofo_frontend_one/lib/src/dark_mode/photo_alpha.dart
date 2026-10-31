import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Area-averaged image alpha in unrotated page orientation. No source colors.
class PhotoAlphaCoverage {
  PhotoAlphaCoverage(this.width, this.height, Uint8List values)
    : values = values.asUnmodifiableView(),
      fingerprint = sha256.convert([
        ...utf8.encode('$width,$height:'),
        ...values,
      ]).toString() {
    if (width < 1 || height < 1 || values.length != width * height) {
      throw ArgumentError('Invalid alpha dimensions');
    }
  }
  final int width, height;
  final Uint8List values;
  final String fingerprint;

  /// Match the centers of alpha samples, with edge clamping inside the panel.
  double sample(double x, double y) {
    final px = (x * width - .5).clamp(0.0, width - 1.0);
    final py = (y * height - .5).clamp(0.0, height - 1.0);
    final x0 = px.floor(), y0 = py.floor();
    final x1 = math.min(x0 + 1, width - 1), y1 = math.min(y0 + 1, height - 1);
    final dx = px - x0, dy = py - y0;
    return (values[y0 * width + x0] * (1 - dx) * (1 - dy) +
            values[y0 * width + x1] * dx * (1 - dy) +
            values[y1 * width + x0] * (1 - dx) * dy +
            values[y1 * width + x1] * dx * dy) /
        255;
  }
}
