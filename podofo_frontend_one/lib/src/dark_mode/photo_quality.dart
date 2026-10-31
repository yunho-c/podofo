/// Session-only developer previews; opaque-only remains the normal behavior.
enum PhotoPreservationMode { opaque, nonzero, recomposeWhite }

/// Temporary rendering experiments. Canonical classification and override
/// identities always use the original 1x / 256-cell analysis.
class PhotoQuality {
  const PhotoQuality({
    this.captureAlpha = false,
    this.alphaScale = 1,
    this.coverageDimension = 256,
    this.textureDimension = 2048,
  }) : assert(alphaScale == 1 || alphaScale == 2 || alphaScale == 4),
       assert(
         coverageDimension == 256 ||
             coverageDimension == 512 ||
             coverageDimension == 1024,
       ),
       assert(textureDimension == 2048 || textureDimension == 4096);

  /// Internal analysis requirement derived from the selected preview mode.
  final bool captureAlpha;
  final int alphaScale, coverageDimension, textureDimension;
  bool get customCoverage => alphaScale != 1 || coverageDimension != 256;

  // Each binary map receives a proportional page allowance. Reserve canonical
  // maps too, even when rendering maps happen to share their storage.
  int get coverageBytesPerMap =>
      512 * 1024 * (coverageDimension ~/ 256) * (coverageDimension ~/ 256);
  // Cap byte-per-cell alpha separately so even 1024-cell previews cache a spread.
  int get alphaBytesPerPage =>
      (coverageBytesPerMap * 8).clamp(0, 8 * 1024 * 1024);
  int get pageCoverageBytes =>
      (customCoverage ? 1024 * 1024 + 2 * coverageBytesPerMap : 1024 * 1024) +
      (captureAlpha ? alphaBytesPerPage : 0);
  static const cacheCoverageBytes = 64 * 1024 * 1024;
  int get cachePages => (cacheCoverageBytes ~/ pageCoverageBytes).clamp(1, 64);

  bool sameCoverage(PhotoQuality other) =>
      captureAlpha == other.captureAlpha &&
      alphaScale == other.alphaScale &&
      coverageDimension == other.coverageDimension;

  PhotoQuality copyWith({
    bool? captureAlpha,
    int? alphaScale,
    int? coverageDimension,
    int? textureDimension,
  }) => PhotoQuality(
    captureAlpha: captureAlpha ?? this.captureAlpha,
    alphaScale: alphaScale ?? this.alphaScale,
    coverageDimension: coverageDimension ?? this.coverageDimension,
    textureDimension: textureDimension ?? this.textureDimension,
  );
}
