import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// A bounded texture of accepted rectangles in document coordinates. It contains
/// coverage only, never PDF pixels, so annotations/selection remain composited.
class PhotoMask {
  PhotoMask(this.image, this.bounds, this.rectangles);
  final ui.Image image;
  final ui.Rect bounds;
  final Set<ui.Rect> rectangles;

  static Future<PhotoMask> create(
    ui.Rect bounds,
    List<ui.Rect> rectangles,
  ) async {
    const maxDimension =
        2048; // At most 16 MiB RGBA; independent of panel count.
    final scale = maxDimension / math.max(bounds.width, bounds.height);
    final width = (bounds.width * scale).ceil().clamp(1, maxDimension);
    final height = (bounds.height * scale).ceil().clamp(1, maxDimension);
    final sx = width / bounds.width, sy = height / bounds.height;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final paint = ui.Paint()
      ..color = const ui.Color(0xffffffff)
      ..isAntiAlias = false;
    final retained = <ui.Rect>{};
    for (final rect in rectangles) {
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
      retained.add(rect);
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

typedef PhotoMaskBuilder = Future<PhotoMask> Function(
  ui.Rect bounds,
  List<ui.Rect> rectangles,
);

class _Request {
  _Request(this.bounds, List<ui.Rect> rectangles)
    : rectangles = List.unmodifiable(rectangles);
  final ui.Rect bounds;
  final List<ui.Rect> rectangles;
  bool same(_Request? other) =>
      other != null &&
      bounds == other.bounds &&
      listEquals(rectangles, other.rectangles);
}

/// One published mask, one in-flight build, and one coalesced latest request.
/// Panning within the same page band changes shader uniforms, not the texture.
class PhotoMaskCache extends ChangeNotifier {
  PhotoMaskCache({PhotoMaskBuilder? builder})
    : _builder = builder ?? PhotoMask.create;
  final PhotoMaskBuilder _builder;
  PhotoMask? current;
  _Request? _wanted, _finished;
  bool _running = false, _disposed = false;
  int _epoch = 0;
  int builds = 0;
  bool failed = false;

  void request(ui.Rect bounds, List<ui.Rect> rectangles) {
    if (_disposed || bounds.isEmpty || !bounds.isFinite) return;
    final request = _Request(bounds, rectangles);
    if (request.same(_wanted)) return;
    _wanted = request;
    if (rectangles.isEmpty) {
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
          result = await _builder(request.bounds, request.rectangles);
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
