import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfrx/pdfrx.dart';

import '../services/pdf_session.dart';
import '../previews/preview_geometry.dart';
import '../previews/link_target.dart';
import '../previews/pdf_link_context.dart';
import '../previews/preview_compositor.dart';
import '../analysis/preview_layout_repository.dart';

/// A preview never changes the viewer matrix or consults its current zoom.
/// All rectangles here are in the rendered (cropped, rotated) page's space.
class LinkPreviewRegion {
  const LinkPreviewRegion(this.rect, this.pageSize, this.pixelRatio);

  static const maxWidth = 360.0;
  static const maxHeight = 240.0;
  final ui.Rect rect;
  final ui.Size pageSize;
  final double pixelRatio;

  double get scale => math.min(
    maxWidth * pixelRatio / rect.width,
    maxHeight * pixelRatio / rect.height,
  );
  int get x => (rect.left * scale).floor();
  int get y => (rect.top * scale).floor();
  int get width => (rect.width * scale).floor().clamp(1, 720);
  int get height => (rect.height * scale).floor().clamp(1, 480);
  double get fullWidth => pageSize.width * scale;
  double get fullHeight => pageSize.height * scale;

  /// [bounds] is PDFium's unrotated page bounding box in raw PDF coordinates.
  /// Link destinations, unlike pdfrx text/link rectangles, retain that origin.
  static LinkPreviewRegion? forDestination(
    PdfPage page,
    PdfDest destination,
    PdfRect bounds,
    double pixelRatio,
  ) {
    if (![
          page.width,
          page.height,
          bounds.width,
          bounds.height,
        ].every((v) => v.isFinite && v > 0) ||
        ![
          bounds.left,
          bounds.top,
          bounds.right,
          bounds.bottom,
        ].every((v) => v.isFinite)) {
      return null;
    }
    final params = destination.params ?? const <double?>[];
    if (params.any((value) => value != null && !value.isFinite)) return null;
    double? parameter(int index) =>
        index < params.length ? params[index] : null;
    double? left, top;
    ui.Rect? region;
    final pageRect = ui.Offset.zero & page.size;
    ui.Rect toPage(PdfRect rect) => previewRectToPage(page, bounds, rect);

    switch (destination.command) {
      case PdfDestCommand.xyz:
        left = parameter(0);
        top = parameter(1);
      case PdfDestCommand.fitH:
      case PdfDestCommand.fitBH:
        top = parameter(0);
      case PdfDestCommand.fitV:
      case PdfDestCommand.fitBV:
        left = parameter(0);
      case PdfDestCommand.fitR:
        if (params.length != 4 || params.any((value) => value == null)) {
          return null;
        }
        if (params[0]! >= params[2]! || params[1]! >= params[3]!) return null;
        final normalized = normalizePreviewDestination(
          page,
          destination,
          bounds,
        );
        if (normalized?.area == null) return null;
        region = normalized!.area!.inflate(12).intersect(pageRect);
        if (region.isEmpty) return null;
      case PdfDestCommand.fit:
      case PdfDestCommand.fitB:
        region = pageRect;
      case PdfDestCommand.unknown:
        return null;
    }

    if (region == null && (left != null || top != null)) {
      final target = toPage(
        PdfRect(
          left ?? (bounds.left + bounds.right) / 2,
          top ?? (bounds.top + bounds.bottom) / 2,
          left ?? (bounds.left + bounds.right) / 2,
          top ?? (bounds.top + bounds.bottom) / 2,
        ),
      ).center;
      final width = math.min(480.0, page.width);
      final height = math.min(320.0, page.height);
      // Center the target in rendered space, retaining surrounding context at
      // every rotation. At page edges, slide the crop back inside the page.
      final x = (target.dx - width / 2).clamp(0.0, page.width - width);
      final y = (target.dy - height / 2).clamp(0.0, page.height - height);
      region = ui.Rect.fromLTWH(x, y, width, height);
    }
    region ??= pageRect; // Page-only destination, including absent coordinates.
    final result = LinkPreviewRegion(
      region,
      page.size,
      boundedPreviewPixelRatio(pixelRatio),
    );
    // Keep PDFium's virtual raster dimensions safe even for pathological pages
    // or a microscopic FitR region on a very large sheet.
    if (!result.fullWidth.isFinite ||
        !result.fullHeight.isFinite ||
        result.fullWidth > 32768 ||
        result.fullHeight > 32768) {
      return null;
    }
    return result;
  }
}

double boundedPreviewPixelRatio(double value) =>
    value.isFinite ? (value.clamp(1.0, 2.0) * 2).ceil() / 2 : 1;

class LinkPreviewCancellation extends PreviewCancellation {
  PdfPageRenderCancellationToken? _token;
  void attach(PdfPageRenderCancellationToken token) {
    _token = token;
    if (isCancelled) token.cancel();
  }

  @override
  void cancel() {
    super.cancel();
    _token?.cancel();
  }
}

typedef LinkPreviewRenderer = Future<ui.Image?> Function(
  PdfDocument document,
  PdfDest destination,
  double pixelRatio,
  LinkPreviewCancellation cancellation,
);

final linkPreviewRendererProvider = Provider<LinkPreviewRenderer>(
  (ref) => renderLinkPreview,
);

/// Runs only while the caller owns the session's read lock and document lease.
Future<ui.Image?> renderLinkPreview(
  PdfDocument document,
  PdfDest destination,
  double pixelRatio,
  LinkPreviewCancellation cancellation,
) async {
  if (cancellation.isCancelled ||
      destination.pageNumber < 1 ||
      destination.pageNumber > document.pages.length ||
      destination.command == PdfDestCommand.unknown) {
    return null;
  }
  final page = document.pages[destination.pageNumber - 1];
  final bounds = await previewPageBounds(document, destination.pageNumber);
  if (bounds == null || cancellation.isCancelled) return null;
  final region = LinkPreviewRegion.forDestination(
    page,
    destination,
    bounds,
    pixelRatio,
  );
  if (region == null) return null;
  return _renderRegion(page, region, cancellation);
}

/// Complete semantic raster, owned by the caller. Composition is all-or-nothing.
Future<ui.Image?> renderResolvedLinkPreview(
  PdfDocument document,
  ResolvedLinkTarget target,
  double pixelRatio,
  LinkPreviewCancellation cancellation, {
  ui.Size maxSize = semanticPreviewMaxSize,
  PreviewRasterAccounting? accounting,
}) => renderPreviewComposition(
  document,
  target,
  pixelRatio,
  cancellation,
  maxSize: maxSize,
  accounting: accounting,
);

Future<ui.Image?> _renderRegion(
  PdfPage page,
  LinkPreviewRegion region,
  LinkPreviewCancellation cancellation,
) async {
  final token = page.createCancellationToken();
  cancellation.attach(token);
  final raster = await page.render(
    x: region.x,
    y: region.y,
    width: region.width,
    height: region.height,
    fullWidth: region.fullWidth,
    fullHeight: region.fullHeight,
    flags: PdfPageRenderFlags.limitedImageCache,
    cancellationToken: token,
  );
  if (raster == null) return null;
  try {
    if (cancellation.isCancelled) return null;
    return await raster.createImage();
  } finally {
    raster.dispose();
  }
}

/// Owns decoded images, avoiding Flutter's global ImageCache. A caller receives
/// a clone and must dispose it; cache eviction cannot invalidate the overlay.
class LinkPreviewCache {
  LinkPreviewCache({this.maxBytes = 6 * 1024 * 1024, this.maxEntries = 8});
  final int maxBytes, maxEntries;
  final _images = <Object, ui.Image>{};
  int bytes = 0;
  int get length => _images.length;

  ui.Image? get(Object key) {
    final image = _images.remove(key);
    if (image == null) return null;
    _images[key] = image;
    return image.clone();
  }

  /// Takes ownership, including when an entry is too large to retain.
  void put(Object key, ui.Image image) {
    _remove(key);
    final size = image.width * image.height * 4;
    if (size > maxBytes || maxEntries <= 0) {
      image.dispose();
      return;
    }
    _images[key] = image;
    bytes += size;
    while (bytes > maxBytes || _images.length > maxEntries) {
      _remove(_images.keys.first);
    }
  }

  void _remove(Object key) {
    final image = _images.remove(key);
    if (image == null) return;
    bytes -= image.width * image.height * 4;
    image.dispose();
  }

  void clear() {
    for (final image in _images.values) {
      image.dispose();
    }
    _images.clear();
    bytes = 0;
  }
}

class _PreviewJob {
  _PreviewJob(
    this.session,
    this.revision,
    this.destination,
    this.pixelRatio,
    this.request,
    this.repository,
    this.onRefinement,
  );
  final LinkPreviewRequest? request;
  final PreviewLayoutRepository? repository;
  final void Function(ui.Image image, ResolvedLinkTarget target)? onRefinement;
  final PdfSession session;
  final int revision;
  final PdfDest destination;
  final double pixelRatio;
  final cancellation = LinkPreviewCancellation();
  final result = Completer<ui.Image?>();
  // PdfDest's hashCode in the pinned engine uses list identity. Use a value key.
  Object get key => (
    request?.identity,
    linkResolverVersion,
    destination.pageNumber,
    destination.command,
    destination.params?.join(','),
    pixelRatio,
  );
  void cancel() {
    cancellation.cancel();
    if (!result.isCompleted) result.complete(null);
  }
}

/// At most one rendering job and one pending request; rapid hovering replaces
/// the pending request. Native work retains its lease even after cancellation.
class LinkPreviewWorker {
  LinkPreviewWorker({this.render = renderLinkPreview});
  final LinkPreviewRenderer render;
  final cache = LinkPreviewCache();
  final context = PdfLinkContext();
  PreparedLinkPreview? _prepared;
  LinkPreviewRequest? _preparedRequest;
  PreparedLinkPreview? get prepared =>
      _preparedRequest?.isCurrent == true ? _prepared : null;
  PdfSession? _session;
  int? _revision;
  _PreviewJob? _active, _pending;
  bool _running = false, _disposed = false;

  Future<ui.Image?> load(
    PdfSession session,
    PdfDest destination, {
    required double pixelRatio,
    LinkPreviewRequest? request,
    PreviewLayoutRepository? repository,
    void Function(ui.Image image, ResolvedLinkTarget target)? onRefinement,
  }) {
    if (_disposed ||
        session.lease.isClosed ||
        (request != null &&
            (!request.isCurrent ||
                !identical(request.session, session) ||
                request.destination != destination))) {
      return Future.value(null);
    }
    if (!identical(_session, session) || _revision != session.revision) {
      reset();
      _session = session;
      _revision = session.revision;
    }
    cancel();
    _prepared = null;
    _preparedRequest = null;
    final job = _PreviewJob(
      session,
      session.revision,
      destination.compact(),
      boundedPreviewPixelRatio(pixelRatio),
      request,
      repository,
      onRefinement,
    );
    _pending = job;
    unawaited(_drain());
    return job.result.future;
  }

  bool _valid(_PreviewJob job) =>
      !_disposed &&
      !job.cancellation.isCancelled &&
      !job.session.lease.isClosed &&
      identical(_session, job.session) &&
      job.session.revision == job.revision;

  Future<void> _drain() async {
    if (_running) return;
    _running = true;
    try {
      while (_pending != null) {
        final job = _pending!;
        _pending = null;
        _active = job;
        ui.Image? image;
        try {
          image =
              cache.get(job.key) ??
              await job.session.readLocked((document) async {
                if (!_valid(job)) return null;
                return render(
                  document,
                  job.destination,
                  job.pixelRatio,
                  job.cancellation,
                );
              });
          if (_valid(job) && image != null) {
            job.result.complete(image.clone());
            cache.put(job.key, image);
            image = null; // Ownership transferred to the cache.
          }
          // Publish context first; preparation uses the same bounded job lane.
          if (!job.result.isCompleted) job.result.complete(null);
          if (_valid(job) && job.request != null) {
            final result = await context.prepare(
              job.request!,
              () => _valid(job),
              job.repository,
              cancellation: job.cancellation,
            );
            if (_valid(job)) {
              _prepared = result;
              _preparedRequest = job.request;
            }
            if (_valid(job) &&
                result?.resolution.tier == LinkTargetTier.matchedIdentity &&
                job.onRefinement != null) {
              final target = result!.resolution;
              final key = target.cacheKey(job.request!);
              image =
                  cache.get(key) ??
                  await job.session.readLocked((pdf) async {
                    if (!_valid(job)) return null;
                    return renderResolvedLinkPreview(
                      pdf,
                      target,
                      job.pixelRatio,
                      job.cancellation,
                      maxSize: job.request!.maxSize,
                    );
                  });
              if (_valid(job) && image != null) {
                final delivered = image.clone();
                cache.put(key, image);
                image = null;
                // A consumer may cancel/reset from this callback. Transfer
                // cache ownership first so that reset cannot repopulate it.
                job.onRefinement!(delivered, target);
              }
            }
          }
        } catch (_) {
          // A failed preview leaves the text tooltip available.
        } finally {
          image?.dispose();
          if (!job.result.isCompleted) job.result.complete(null);
          _active = null;
        }
      }
    } finally {
      _running = false;
    }
  }

  void cancel() {
    _prepared = null;
    _preparedRequest = null;
    _active?.cancel();
    _pending?.cancel();
    _pending = null;
  }

  void reset() {
    cancel();
    cache.clear();
    context.clear();
    _prepared = null;
    _preparedRequest = null;
    _session = null;
    _revision = null;
  }

  void dispose() {
    _disposed = true;
    reset();
  }
}
