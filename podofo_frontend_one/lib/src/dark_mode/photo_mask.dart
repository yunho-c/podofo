import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import 'photo_coverage.dart';
import 'photo_alpha.dart';

/// A candidate projected into document layout. Coverage is stored before page
/// rotation, so only the page's quarter-turn needs applying here.
class PhotoMaskRegion {
  const PhotoMaskRegion(
    this.rect, {
    this.coverage,
    this.alpha,
    this.quarterTurns = 0,
  });
  final ui.Rect rect;
  final PhotoCoverage? coverage;
  final PhotoAlphaCoverage? alpha;
  final int quarterTurns;

  bool covers(double left, double top, double right, double bottom) {
    final c = coverage;
    if (c == null) return true;
    return switch (quarterTurns) {
      1 => c.covers(top, 1 - right, bottom, 1 - left),
      2 => c.covers(1 - right, 1 - bottom, 1 - left, 1 - top),
      3 => c.covers(1 - bottom, left, 1 - top, right),
      _ => c.covers(left, top, right, bottom),
    };
  }

  double alphaAt(double x, double y) => switch (quarterTurns) {
    1 => alpha!.sample(y, 1 - x),
    2 => alpha!.sample(1 - x, 1 - y),
    3 => alpha!.sample(1 - y, x),
    _ => alpha!.sample(x, y),
  };

  @override
  bool operator ==(Object other) =>
      other is PhotoMaskRegion &&
      rect == other.rect &&
      quarterTurns == other.quarterTurns &&
      coverage?.fingerprint == other.coverage?.fingerprint &&
      alpha?.fingerprint == other.alpha?.fingerprint;
  @override
  int get hashCode => Object.hash(
    rect,
    quarterTurns,
    coverage?.fingerprint,
    alpha?.fingerprint,
  );
}

/// A bounded texture of accepted coverage and optional fractional alpha in
/// document coordinates. Never stores source RGB. Recomposition requires the
/// caller to exclude native annotations and active viewer overlays.
class PhotoMask {
  PhotoMask(this.image, this.bounds, this.regions);
  final ui.Image image;
  final ui.Rect bounds;

  /// Candidates contributing at least one opaque texel, not their entire AABB.
  final Set<PhotoMaskRegion> regions;

  static Future<PhotoMask> create(
    ui.Rect bounds,
    List<PhotoMaskRegion> regions, {
    int maxDimension = 2048,
  }) async {
    assert(maxDimension == 2048 || maxDimension == 4096);
    final scale = maxDimension / math.max(bounds.width, bounds.height);
    final width = (bounds.width * scale).ceil().clamp(1, maxDimension);
    final height = (bounds.height * scale).ceil().clamp(1, maxDimension);
    final sx = width / bounds.width, sy = height / bounds.height;
    if (regions.any((r) => r.coverage != null || r.alpha != null)) {
      final raster = await _rasterizeOffThread(bounds, width, height, regions);
      final buffer = await ui.ImmutableBuffer.fromUint8List(raster.$1);
      ui.ImageDescriptor? descriptor;
      ui.Codec? codec;
      try {
        descriptor = ui.ImageDescriptor.raw(
          buffer,
          width: width,
          height: height,
          pixelFormat: ui.PixelFormat.rgba8888,
        );
        codec = await descriptor.instantiateCodec();
        return PhotoMask((await codec.getNextFrame()).image, bounds, raster.$2);
      } finally {
        codec?.dispose();
        descriptor?.dispose();
        buffer.dispose();
      }
    }
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final paint = ui.Paint()
      ..color = const ui.Color(0xffffffff)
      ..isAntiAlias = false;
    final retained = <PhotoMaskRegion>{};
    for (final region in regions) {
      final rect = region.rect;
      final clipped = rect.intersect(bounds);
      if (clipped.isEmpty) continue;
      // Only fill whole texels contained in an accepted region. Linear texture
      // filtering plus a full-alpha threshold then keeps edges conservative.
      final pixels = ui.Rect.fromLTRB(
        ((clipped.left - bounds.left) * sx).ceilToDouble(),
        ((clipped.top - bounds.top) * sy).ceilToDouble(),
        ((clipped.right - bounds.left) * sx).floorToDouble(),
        ((clipped.bottom - bounds.top) * sy).floorToDouble(),
      );
      if (pixels.isEmpty) continue;
      canvas.drawRect(pixels, paint);
      retained.add(region);
    }
    final picture = recorder.endRecording();
    try {
      return PhotoMask(await picture.toImage(width, height), bounds, retained);
    } finally {
      picture.dispose();
    }
  }

  void configure(ui.FragmentShader shader, double strength, ui.Rect viewport) {
    shader
      ..setFloat(2, strength.clamp(0, 1))
      ..setFloat(3, (viewport.left - bounds.left) / bounds.width)
      ..setFloat(4, (viewport.top - bounds.top) / bounds.height)
      ..setFloat(5, viewport.width / bounds.width)
      ..setFloat(6, viewport.height / bounds.height)
      ..setImageSampler(1, image);
  }

  void dispose() => image.dispose();
}

// Isolate closure lives outside PhotoMask so it cannot capture a native image.
Future<(Uint8List, Set<PhotoMaskRegion>)> _rasterizeOffThread(
  ui.Rect bounds,
  int width,
  int height,
  List<PhotoMaskRegion> regions,
) => Isolate.run(() => _rasterize(bounds, width, height, regions));

(Uint8List, Set<PhotoMaskRegion>) _rasterize(
  ui.Rect bounds,
  int width,
  int height,
  List<PhotoMaskRegion> regions,
) {
  final rgba = Uint8List(width * height * 4);
  final pixels = Uint32List.view(rgba.buffer);
  final retained = <PhotoMaskRegion>{};
  final sx = width / bounds.width, sy = height / bounds.height;
  for (final region in regions) {
    final rect = region.rect;
    final clip = rect.intersect(bounds);
    if (clip.isEmpty) continue;
    final left = ((clip.left - bounds.left) * sx).ceil().clamp(0, width);
    final right = ((clip.right - bounds.left) * sx).floor().clamp(left, width);
    final top = ((clip.top - bounds.top) * sy).ceil().clamp(0, height);
    final bottom = ((clip.bottom - bounds.top) * sy).floor().clamp(top, height);
    var contributed = false;
    for (var y = top; y < bottom; y++) {
      if (region.coverage == null && region.alpha == null) {
        pixels.fillRange(y * width + left, y * width + right, 0xffffffff);
        contributed |= right > left;
        continue;
      }
      final t = (bounds.top + y / sy - rect.top) / rect.height;
      final b = (bounds.top + (y + 1) / sy - rect.top) / rect.height;
      for (var x = left; x < right; x++) {
        final l = (bounds.left + x / sx - rect.left) / rect.width;
        final r = (bounds.left + (x + 1) / sx - rect.left) / rect.width;
        if (region.alpha != null) {
          // A=255 is the supported region; R carries fractional image alpha.
          // G=0 distinguishes correction from legacy white preservation texels.
          final alpha = (region.alphaAt((l + r) / 2, (t + b) / 2) * 255)
              .round()
              .clamp(0, 255);
          final offset = (y * width + x) * 4;
          rgba[offset] = alpha;
          rgba[offset + 1] = 0;
          rgba[offset + 2] = 0;
          rgba[offset + 3] = 255;
          contributed = true;
        } else if (region.covers(l, t, r, b)) {
          pixels[y * width + x] = 0xffffffff;
          contributed = true;
        }
      }
    }
    if (contributed) retained.add(region);
  }
  return (rgba, retained);
}

typedef PhotoMaskBuilder = Future<PhotoMask> Function(
  ui.Rect bounds,
  List<PhotoMaskRegion> regions,
);

class _Request {
  _Request(this.bounds, List<PhotoMaskRegion> regions)
    : regions = List.unmodifiable(regions);
  final ui.Rect bounds;
  final List<PhotoMaskRegion> regions;
  bool same(_Request? other) =>
      other != null &&
      bounds == other.bounds &&
      listEquals(regions, other.regions);
}

/// One published mask, one in-flight build, and one coalesced latest request.
/// Panning within the same page band changes shader uniforms, not the texture.
class PhotoMaskCache extends ChangeNotifier {
  PhotoMaskCache({PhotoMaskBuilder? builder, int maxDimension = 2048})
    : _builder =
          builder ??
          ((bounds, regions) =>
              PhotoMask.create(bounds, regions, maxDimension: maxDimension));
  final PhotoMaskBuilder _builder;
  PhotoMask? current;
  _Request? _wanted, _finished;
  bool _running = false, _disposed = false;
  int _epoch = 0;
  int builds = 0;
  bool failed = false;

  void request(ui.Rect bounds, List<PhotoMaskRegion> regions) {
    if (_disposed || bounds.isEmpty || !bounds.isFinite) return;
    final request = _Request(bounds, regions);
    if (request.same(_wanted)) return;
    _wanted = request;
    if (regions.isEmpty) {
      _epoch++;
      _finished = request;
      failed = false;
      _retire(current);
      current = null;
      return;
    }
    if (!_running) _drain();
  }

  Future<void> _drain() async {
    _running = true;
    // Requests originate in build; never publish or start GPU work synchronously.
    await Future<void>.delayed(Duration.zero);
    try {
      while (!_disposed && _wanted != null && !_wanted!.same(_finished)) {
        final request = _wanted!;
        final epoch = _epoch;
        PhotoMask? result;
        try {
          builds++;
          result = await _builder(request.bounds, request.regions);
        } catch (_) {
          // Keep a valid older mask; report the failed request without a retry loop.
        }
        if (_disposed || epoch != _epoch || !request.same(_wanted)) {
          result?.dispose();
          continue;
        }
        _finished = request;
        failed = result == null;
        if (result != null) {
          final old = current;
          current = result;
          _retire(old);
        }
        notifyListeners();
      }
    } finally {
      _running = false;
    }
  }

  void invalidate() {
    _epoch++;
    _wanted = _finished = null;
    failed = false;
    _retire(current);
    current = null;
  }

  void _retire(PhotoMask? mask) {
    if (mask == null) return;
    // The previous layer can reference this image until the current frame ends.
    SchedulerBinding.instance.addPostFrameCallback((_) => mask.dispose());
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    _disposed = true;
    invalidate();
    super.dispose();
  }
}
