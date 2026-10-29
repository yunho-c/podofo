import 'dart:math' as math;
import 'dart:typed_data';

/// A deliberately conservative texture heuristic, not semantic recognition.
/// All input is a fixed 64 x 64 RGB sample; no source pixels are retained.
class PhotoClassification {
  const PhotoClassification(
    this.isLikelyPhoto,
    this.reason, {
    this.entropy = 0,
    this.colors = 0,
    this.flatFraction = 1,
    this.edgeFraction = 0,
    this.extremeFraction = 0,
    this.texturedTiles = 0,
  });

  final bool isLikelyPhoto;
  final String reason;
  final double entropy;
  final int colors;
  final double flatFraction;
  final double edgeFraction;
  final double extremeFraction;
  final int texturedTiles;
}

PhotoClassification classifyPhoto(Uint8List rgb) {
  const side = 64;
  if (rgb.length != side * side * 3) {
    return const PhotoClassification(false, 'invalid-sample');
  }
  final histogram = List<int>.filled(64, 0);
  final tileTexture = List<int>.filled(16, 0);
  final colors = <int>{};
  final luminance = List<int>.filled(side * side, 0);
  var extreme = 0;
  for (var i = 0; i < luminance.length; i++) {
    final r = rgb[i * 3];
    final g = rgb[i * 3 + 1];
    final b = rgb[i * 3 + 2];
    final l = (77 * r + 150 * g + 29 * b) >> 8;
    luminance[i] = l;
    histogram[l >> 2]++;
    colors.add(((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4));
    if (l < 12 || l > 243) extreme++;
  }
  var flat = 0;
  var edges = 0;
  var pairs = 0;
  for (var y = 0; y < side; y++) {
    for (var x = 0; x < side; x++) {
      final i = y * side + x;
      for (final j in [if (x + 1 < side) i + 1, if (y + 1 < side) i + side]) {
        final delta = (luminance[i] - luminance[j]).abs();
        pairs++;
        if (delta <= 2) flat++;
        if (delta >= 64) edges++;
        // Moderate local variation distributed across the image rejects smooth
        // gradients, flat plots and many screenshots, even with high entropy.
        if (delta >= 6 && delta <= 48) tileTexture[(y ~/ 16) * 4 + x ~/ 16]++;
      }
    }
  }
  var entropy = 0.0;
  for (final count in histogram) {
    if (count == 0) continue;
    final p = count / luminance.length;
    entropy -= p * math.log(p) / math.ln2;
  }
  final flatFraction = flat / pairs;
  final edgeFraction = edges / pairs;
  final extremeFraction = extreme / luminance.length;
  final texturedTiles = tileTexture.where((count) => count >= 100).length;
  final reason = entropy < 4.5
      ? 'low-tonal-entropy'
      : colors.length < 90
      ? 'limited-palette'
      : flatFraction > .45
      ? 'flat-regions'
      : edgeFraction > .18
      ? 'hard-edges'
      : extremeFraction > .30
      ? 'paper-or-black-background'
      : texturedTiles < 10
      ? 'insufficient-distributed-texture'
      : 'likely-photo';
  return PhotoClassification(
    reason == 'likely-photo',
    reason,
    entropy: entropy,
    colors: colors.length,
    flatFraction: flatFraction,
    edgeFraction: edgeFraction,
    extremeFraction: extremeFraction,
    texturedTiles: texturedTiles,
  );
}
