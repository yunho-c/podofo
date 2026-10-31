import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:pdfrx/pdfrx.dart';

import 'link_target.dart';

/// Accounted application raster payloads only. PDFium internals, decoder staging,
/// UI images and framework/GPU allocations are outside these transient counters.
class PreviewRasterAccounting {
  int compositeBytes = 0, cropBytes = 0, peakBytes = 0, crops = 0;
  int get liveBytes => compositeBytes + cropBytes;
  void _record() => peakBytes = math.max(peakBytes, liveBytes);
}

class PreviewCrop {
  const PreviewCrop({
    required this.page,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.outputX,
    required this.outputY,
    required this.fullWidth,
    required this.fullHeight,
  });
  final int page, x, y, width, height, outputX, outputY;
  final double fullWidth, fullHeight;
  int get bytes => width * height * 4;
}

/// Ordered, uniformly scaled original-pixel slices. Never stretch or reflow text.
class PreviewComposition {
  PreviewComposition._(this.width, this.height, this.crops);
  static const maxBytes = 960 * 720 * 4;
  final int width, height;
  final List<PreviewCrop> crops;
  int get bytes => width * height * 4;

  static PreviewComposition? plan(
    PdfDocument document,
    ResolvedLinkTarget target,
    double pixelRatio, {
    ui.Size maxSize = semanticPreviewMaxSize,
  }) {
    final parts = target.parts;
    if (parts.isEmpty ||
        parts.length > 4 ||
        ![maxSize.width, maxSize.height].every((v) => v.isFinite && v > 0)) {
      return null;
    }
    final pages = parts.map((p) => p.page).toSet().toList()..sort();
    if (pages.length > 2 ||
        pages.last - pages.first > 1 ||
        pages.first < 1 ||
        pages.last > document.pages.length) {
      return null;
    }
    for (var i = 0; i < parts.length; i++) {
      final part = parts[i], page = document.pages[parts[i].page - 1];
      if (i > 0 && part.page < parts[i - 1].page) return null;
      final rect = part.bounds;
      if (rect.isEmpty ||
          ![
            rect.left,
            rect.top,
            rect.right,
            rect.bottom,
            page.width,
            page.height,
          ].every((v) => v.isFinite) ||
          rect != rect.intersect(ui.Offset.zero & page.size)) {
        return null;
      }
    }
    final ratio = pixelRatio.isFinite ? pixelRatio.clamp(1.0, 2.0) : 1.0;
    final maxWidth = (math.min(480, maxSize.width) * ratio).floor();
    final maxHeight = (math.min(360, maxSize.height) * ratio).floor();
    final gap = (8 * ratio).ceil();
    final naturalWidth = parts.map((p) => p.bounds.width).reduce(math.max);
    final naturalHeight = parts.fold(0.0, (sum, p) => sum + p.bounds.height);
    // Up to two edge pixels per crop retain fractional source coordinates.
    final scale = math.min(
      (maxWidth - 2) / naturalWidth,
      (maxHeight - gap * (parts.length - 1) - 2 * parts.length) / naturalHeight,
    );
    if (!scale.isFinite || scale <= 0) return null;
    final preliminary = <PreviewCrop>[];
    var width = 0, height = 0;
    for (final part in parts) {
      final page = document.pages[part.page - 1];
      final x = (part.bounds.left * scale).floor(),
          y = (part.bounds.top * scale).floor();
      final w = (part.bounds.right * scale).ceil() - x;
      final h = (part.bounds.bottom * scale).ceil() - y;
      final fw = page.width * scale, fh = page.height * scale;
      if (w <= 0 ||
          h <= 0 ||
          fw > 32768 ||
          fh > 32768 ||
          !fw.isFinite ||
          !fh.isFinite) {
        return null;
      }
      preliminary.add(
        PreviewCrop(
          page: part.page,
          x: x,
          y: y,
          width: w,
          height: h,
          outputX: 0,
          outputY: height,
          fullWidth: fw,
          fullHeight: fh,
        ),
      );
      width = math.max(width, w);
      height += h + gap;
    }
    height -= gap;
    if (width > maxWidth ||
        height > maxHeight ||
        width * height * 4 > maxBytes) {
      return null;
    }
    return PreviewComposition._(
      width,
      height,
      List.unmodifiable([
        for (final crop in preliminary)
          PreviewCrop(
            page: crop.page,
            x: crop.x,
            y: crop.y,
            width: crop.width,
            height: crop.height,
            outputX: (width - crop.width) ~/ 2,
            outputY: crop.outputY,
            fullWidth: crop.fullWidth,
            fullHeight: crop.fullHeight,
          ),
      ]),
    );
  }
}

/// The caller holds its PDF lease/read lock. A failed slice discards the entire
/// composite. Only one native crop is retained alongside the composite buffer.
Future<ui.Image?> renderPreviewComposition(
  PdfDocument document,
  ResolvedLinkTarget target,
  double pixelRatio,
  PreviewCancellation cancellation, {
  ui.Size maxSize = semanticPreviewMaxSize,
  PreviewRasterAccounting? accounting,
}) async {
  if (cancellation.isCancelled) return null;
  final plan = PreviewComposition.plan(
    document,
    target,
    pixelRatio,
    maxSize: maxSize,
  );
  if (plan == null) return null;
  final pixels = Uint8List(plan.bytes)..fillRange(0, plan.bytes, 255);
  accounting?.compositeBytes += pixels.length;
  accounting?._record();
  try {
    for (final crop in plan.crops) {
      if (cancellation.isCancelled) return null;
      final page = document.pages[crop.page - 1];
      final token = page.createCancellationToken();
      final remove = cancellation.onCancel(token.cancel);
      PdfImage? raster;
      try {
        raster = await page.render(
          x: crop.x,
          y: crop.y,
          width: crop.width,
          height: crop.height,
          fullWidth: crop.fullWidth,
          fullHeight: crop.fullHeight,
          backgroundColor: 0xffffffff,
          flags: PdfPageRenderFlags.limitedImageCache,
          cancellationToken: token,
        );
        if (raster == null) return null;
        accounting?.cropBytes += crop.bytes;
        accounting?.crops++;
        accounting?._record();
        if (cancellation.isCancelled ||
            raster.width != crop.width ||
            raster.height != crop.height) {
          return null;
        }
        final source = raster.pixels;
        if (source.length != crop.bytes) return null;
        for (var row = 0; row < crop.height; row++) {
          final offset = ((crop.outputY + row) * plan.width + crop.outputX) * 4;
          pixels.setRange(
            offset,
            offset + crop.width * 4,
            source,
            row * crop.width * 4,
          );
        }
      } finally {
        remove();
        if (raster != null) {
          raster.dispose();
          accounting?.cropBytes -= crop.bytes;
        }
      }
    }
    if (cancellation.isCancelled) return null;
    final buffer = await ui.ImmutableBuffer.fromUint8List(pixels);
    try {
      final descriptor = ui.ImageDescriptor.raw(
        buffer,
        width: plan.width,
        height: plan.height,
        rowBytes: plan.width * 4,
        pixelFormat: ui.PixelFormat.bgra8888,
      );
      try {
        final codec = await descriptor.instantiateCodec();
        try {
          final image = (await codec.getNextFrame()).image;
          if (cancellation.isCancelled) {
            image.dispose();
            return null;
          }
          return image;
        } finally {
          codec.dispose();
        }
      } finally {
        descriptor.dispose();
      }
    } finally {
      buffer.dispose();
    }
  } finally {
    accounting?.compositeBytes -= pixels.length;
  }
}
