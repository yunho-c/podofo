/// Temporary rendering experiments. Canonical classification and override
/// identities always use the original 1x / 256-cell analysis.
class PhotoQuality {
  const PhotoQuality({
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

  final int alphaScale, coverageDimension, textureDimension;
  bool get customCoverage => alphaScale != 1 || coverageDimension != 256;

  // Each binary map receives a proportional page allowance. Reserve canonical
  // maps too, even when rendering maps happen to share their storage.
  int get coverageBytesPerMap =>
      512 * 1024 * (coverageDimension ~/ 256) * (coverageDimension ~/ 256);
  int get pageCoverageBytes =>
      customCoverage ? 1024 * 1024 + 2 * coverageBytesPerMap : 1024 * 1024;
  static const cacheCoverageBytes = 64 * 1024 * 1024;
  int get cachePages => (cacheCoverageBytes ~/ pageCoverageBytes).clamp(1, 64);

  bool sameCoverage(PhotoQuality other) =>
      alphaScale == other.alphaScale &&
      coverageDimension == other.coverageDimension;

  PhotoQuality copyWith({
    int? alphaScale,
    int? coverageDimension,
    int? textureDimension,
  }) => PhotoQuality(
    alphaScale: alphaScale ?? this.alphaScale,
    coverageDimension: coverageDimension ?? this.coverageDimension,
    textureDimension: textureDimension ?? this.textureDimension,
  );
}
