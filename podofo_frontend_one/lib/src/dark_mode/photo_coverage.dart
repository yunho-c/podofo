import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Detached binary coverage over the candidate's visible rectangle, in
/// unrotated page orientation with rows running top to bottom. A set cell means
/// its entire footprint met the selected alpha criterion at PDFium's local
/// image-render resolution (opaque by default, nonzero in the developer preview).
class PhotoCoverage {
  PhotoCoverage._(this.width, this.height, this.bits, this.opaqueCells)
    : fingerprint = sha256.convert([
        ...utf8.encode('$width,$height:'),
        ...bits,
      ]).toString();

  factory PhotoCoverage.fromCells(int width, int height, Uint8List cells) {
    if (width <= 0 || height <= 0 || cells.length != width * height) {
      throw ArgumentError('Invalid coverage dimensions');
    }
    final bits = Uint8List((cells.length + 7) ~/ 8);
    var count = 0;
    for (var i = 0; i < cells.length; i++) {
      if (cells[i] == 0) continue;
      bits[i >> 3] |= 1 << (i & 7);
      count++;
    }
    return PhotoCoverage._(width, height, bits.asUnmodifiableView(), count);
  }

  final int width, height, opaqueCells;
  final Uint8List bits;
  final String fingerprint;
  bool get isEmpty => opaqueCells == 0;
  bool get isFull => opaqueCells == width * height;
  double get fraction => opaqueCells / (width * height);

  bool at(int x, int y) {
    final i = y * width + x;
    return (bits[i >> 3] & (1 << (i & 7))) != 0;
  }

  /// Conservative min-pooling: every cell touched by a destination footprint
  /// must be set. In particular, shrinking never averages away a small hole.
  bool covers(double left, double top, double right, double bottom) {
    if (left < -1e-9 ||
        top < -1e-9 ||
        right > 1 + 1e-9 ||
        bottom > 1 + 1e-9 ||
        left >= right ||
        top >= bottom) {
      return false;
    }
    final x0 = (left * width).floor().clamp(0, width - 1);
    final x1 = (right * width).ceil().clamp(x0 + 1, width);
    final y0 = (top * height).floor().clamp(0, height - 1);
    final y1 = (bottom * height).ceil().clamp(y0 + 1, height);
    for (var y = y0; y < y1; y++) {
      for (var x = x0; x < x1; x++) {
        if (!at(x, y)) return false;
      }
    }
    return true;
  }
}
