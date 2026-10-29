import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

typedef PixelRect = ({int left, int top, int right, int bottom});

img.Image rgbaImage(Uint8List bytes, int width, int height) =>
    img.Image.fromBytes(
      width: width,
      height: height,
      bytes: bytes.buffer,
      bytesOffset: bytes.offsetInBytes,
      numChannels: 4,
      order: img.ChannelOrder.rgba,
    );

double _luma(Uint8List p, int i) =>
    .2126 * p[i] + .7152 * p[i + 1] + .0722 * p[i + 2];

/// Differences use 8-bit sRGB code values, not a perceptual quality model.
Map<String, Object?> measure(
  Uint8List reference,
  Uint8List candidate,
  int width,
  int height,
  PixelRect rect,
) {
  if (reference.length != width * height * 4 ||
      candidate.length != reference.length) {
    throw ArgumentError('Raster dimensions do not match');
  }
  if (rect.left < 0 ||
      rect.top < 0 ||
      rect.right > width ||
      rect.bottom > height ||
      rect.right <= rect.left ||
      rect.bottom <= rect.top) {
    throw ArgumentError('Empty or out-of-bounds scoring region');
  }
  var absolute = 0.0, squared = 0.0, refEdge = 0.0, candidateEdge = 0.0;
  var changed = 0, refInk = 0, candidateInk = 0;
  for (var y = rect.top; y < rect.bottom; y++) {
    for (var x = rect.left; x < rect.right; x++) {
      final i = (y * width + x) * 4;
      var maxDelta = 0;
      for (var c = 0; c < 3; c++) {
        final d = (reference[i + c] - candidate[i + c]).abs();
        absolute += d;
        squared += d * d;
        maxDelta = math.max(maxDelta, d);
      }
      if (maxDelta > 2) changed++;
      final a = _luma(reference, i), b = _luma(candidate, i);
      if (a < 127.5) refInk++;
      if (b < 127.5) candidateInk++;
      if (x + 1 < rect.right) {
        refEdge += (a - _luma(reference, i + 4)).abs();
        candidateEdge += (b - _luma(candidate, i + 4)).abs();
      }
      if (y + 1 < rect.bottom) {
        refEdge += (a - _luma(reference, i + width * 4)).abs();
        candidateEdge += (b - _luma(candidate, i + width * 4)).abs();
      }
    }
  }
  final n = (rect.right - rect.left) * (rect.bottom - rect.top);
  return {
    'pixels': n,
    'rect': [rect.left, rect.top, rect.right, rect.bottom],
    'mae_8bit': absolute / (3 * n),
    'rmse_8bit': math.sqrt(squared / (3 * n)),
    'different_fraction_gt_2': changed / n,
    'reference_ink_fraction': refInk / n,
    'candidate_ink_fraction': candidateInk / n,
    'edge_energy_ratio': refEdge == 0 ? null : candidateEdge / refEdge,
  };
}

img.Image differenceImage(
  Uint8List reference,
  Uint8List candidate,
  int width,
  int height,
) {
  final heat = img.Image(width: width, height: height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final i = (y * width + x) * 4;
      final d = math.max(
        (reference[i] - candidate[i]).abs(),
        math.max(
          (reference[i + 1] - candidate[i + 1]).abs(),
          (reference[i + 2] - candidate[i + 2]).abs(),
        ),
      );
      heat.setPixelRgb(x, y, math.min(d * 8, 255), 0, 0);
    }
  }
  return heat;
}

/// Validate the measurement path using controlled changes, not current viewer output.
Map<String, Object?> calibration() {
  final source = img.Image(width: 96, height: 96, numChannels: 4);
  img.fill(source, color: img.ColorRgba8(255, 255, 255, 255));
  for (var x = 10; x < 85; x += 8) {
    img.fillRect(
      source,
      x1: x,
      y1: 8,
      x2: x + 2,
      y2: 87,
      color: img.ColorRgba8(0, 0, 0, 255),
    );
  }
  final ref = source.getBytes(order: img.ChannelOrder.rgba);
  const rect = (left: 4, top: 4, right: 92, bottom: 92);
  final blur = img.gaussianBlur(source.clone(), radius: 2);
  final shifted = img.Image.from(source);
  img.fill(shifted, color: img.ColorRgba8(255, 255, 255, 255));
  img.compositeImage(shifted, source, dstX: 1);
  final undersized = img.copyResize(
    img.copyResize(
      source,
      width: 32,
      height: 32,
      interpolation: img.Interpolation.average,
    ),
    width: 96,
    height: 96,
    interpolation: img.Interpolation.linear,
  );
  Map<String, Object?> score(img.Image candidate) => measure(
    ref,
    candidate.getBytes(order: img.ChannelOrder.rgba),
    96,
    96,
    rect,
  );
  final same = score(source),
      blurred = score(blur),
      shift = score(shifted),
      small = score(undersized);
  if (same['mae_8bit'] != 0 ||
      [blurred, shift, small].any((m) => (m['mae_8bit'] as double) < 1) ||
      (blurred['edge_energy_ratio'] as double) >= .9) {
    throw StateError('Measurement calibration failed');
  }
  return {
    'passed': true,
    'identical': same,
    'blurred': blurred,
    'shifted_1px': shift,
    'undersized': small,
  };
}
