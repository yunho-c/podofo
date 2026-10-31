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
    this.requiredTexturedTiles = 10,
    this.visibleSamples = 4096,
  });

  final bool isLikelyPhoto;
  final String reason;
  final double entropy;
  final int colors;
  final double flatFraction;
  final double edgeFraction;
  final double extremeFraction;
  final int texturedTiles;
  final int requiredTexturedTiles, visibleSamples;
}

PhotoClassification classifyPhoto(Uint8List rgb, {Uint8List? opaque}) {
  const side = 64;
  if (rgb.length != side * side * 3 ||
      (opaque != null && opaque.length != side * side)) {
    return const PhotoClassification(false, 'invalid-sample');
  }
  final histogram = List<int>.filled(64, 0);
  final tileTexture = List<int>.filled(16, 0);
  final tilePairs = List<int>.filled(16, 0);
  final colors = <int>{};
  final luminance = List<int>.filled(side * side, 0);
  var extreme = 0, samples = 0;
  for (var i = 0; i < luminance.length; i++) {
    if (opaque != null && opaque[i] == 0) continue;
    samples++;
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
      if (opaque != null && opaque[i] == 0) continue;
      for (final j in [if (x + 1 < side) i + 1, if (y + 1 < side) i + side]) {
        if (opaque != null && opaque[j] == 0) continue;
        final delta = (luminance[i] - luminance[j]).abs();
        pairs++;
        tilePairs[(y ~/ 16) * 4 + x ~/ 16]++;
        if (delta <= 2) flat++;
        if (delta >= 64) edges++;
        // Moderate local variation distributed across the image rejects smooth
        // gradients, flat plots and many screenshots, even with high entropy.
        if (delta >= 6 && delta <= 48) tileTexture[(y ~/ 16) * 4 + x ~/ 16]++;
      }
    }
  }
  if (samples < 256 || pairs < 256) {
    return PhotoClassification(
      false,
      'insufficient-visible-samples',
      visibleSamples: samples,
    );
  }
  var entropy = 0.0;
  for (final count in histogram) {
    if (count == 0) continue;
    final p = count / samples;
    entropy -= p * math.log(p) / math.ln2;
  }
  final flatFraction = flat / pairs;
  final edgeFraction = edges / pairs;
  final extremeFraction = extreme / samples;
  // Preserve the existing full-image thresholds exactly. For a masked image,
  // compare moderate differences only between visible neighbors and require
  // texture in the same proportion of sufficiently sampled tiles.
  final eligible = [
    for (var i = 0; i < 16; i++)
      if (opaque == null || tilePairs[i] >= 64) i,
  ];
  final texturedTiles = eligible
      .where(
        (i) => opaque == null
            ? tileTexture[i] >= 100
            : tileTexture[i] / tilePairs[i] >= 100 / 512,
      )
      .length;
  final requiredTiles = opaque == null
      ? 10
      : math.max(1, (eligible.length * 10 / 16).ceil());
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
      : texturedTiles < requiredTiles
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
    requiredTexturedTiles: requiredTiles,
    visibleSamples: samples,
  );
}
