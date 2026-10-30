import 'dart:ffi';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:pdfium_dart/pdfium_dart.dart';

import 'photo_classifier.dart';

/// Crop-relative, unrotated PDF coordinates (positive y upwards), like pdfrx.
class PhotoRegion {
  const PhotoRegion(this.left, this.bottom, this.right, this.top);
  final double left, bottom, right, top;
  double get area => (right - left) * (top - bottom);
  bool overlaps(PhotoRegion other) =>
      left < other.right &&
      right > other.left &&
      bottom < other.top &&
      top > other.bottom;
}

class PhotoCandidate {
  const PhotoCandidate(
    this.objectIndex,
    this.reason, {
    required this.region,
    this.classification,
    this.objectPath = const [],
  });
  final int objectIndex;

  /// Zero-based path through page objects and nested Form children.
  final List<int> objectPath;
  String get objectId =>
      objectPath.isEmpty ? objectIndex.toString() : objectPath.join('/');
  final String reason;
  final PhotoRegion region;
  final PhotoClassification? classification;
}

class PhotoPageAnalysis {
  const PhotoPageAnalysis({
    this.regions = const [],
    this.candidates = const [],
    this.fallback,
    this.elapsedMicroseconds = 0,
    this.pendingCount = 0,
    this.batchDecodedImages = 0,
    this.batchDecodedPixels = 0,
  }) : _pending = const [];

  PhotoPageAnalysis._(
    List<PhotoCandidate> results,
    List<_PendingImage> pending, {
    this.elapsedMicroseconds = 0,
    this.batchDecodedImages = 0,
    this.batchDecodedPixels = 0,
  }) : candidates = List.unmodifiable(results),
       regions = List.unmodifiable(
         results.where((c) => c.reason == 'likely-photo').map((c) => c.region),
       ),
       _pending = List.unmodifiable(pending),
       pendingCount = pending.length,
       fallback = null;

  /// Stop a failed continuation without discarding photos already classified.
  factory PhotoPageAnalysis.failed(PhotoPageAnalysis? previous, String reason) {
    final results = [
      for (final c in previous?.candidates ?? const <PhotoCandidate>[])
        c.reason == 'pending'
            ? PhotoCandidate(
                c.objectIndex,
                reason,
                region: c.region,
                objectPath: c.objectPath,
              )
            : c,
    ];
    return PhotoPageAnalysis(
      candidates: List.unmodifiable(results),
      regions: List.unmodifiable(
        results.where((c) => c.reason == 'likely-photo').map((c) => c.region),
      ),
      fallback: reason,
    );
  }

  final List<PhotoRegion> regions;
  final List<PhotoCandidate> candidates;
  final String? fallback;
  final int elapsedMicroseconds,
      pendingCount,
      batchDecodedImages,
      batchDecodedPixels;
  final List<_PendingImage> _pending;
  bool get isComplete => pendingCount == 0;
  int get totalImages => candidates.length;
  int get inspectedImages => totalImages - pendingCount;
  int get omittedDiagnosticObjects => math.max(0, candidates.length - 128);
}

/// Complete-page convenience for qualification tools. The viewer uses one batch
/// per session read lock, yielding to pdfrx and other visible pages between calls.
Future<PhotoPageAnalysis> analyzePhotos(
  PdfDocument document,
  int pageNumber,
) async {
  PhotoPageAnalysis? result;
  do {
    result = await analyzePhotoBatch(document, pageNumber, previous: result);
  } while (!result.isComplete);
  return result;
}

/// Only detached metadata crosses batches. Caller supplies results from the same
/// session, page and revision, and holds its read lock until this call completes.
Future<PhotoPageAnalysis> analyzePhotoBatch(
  PdfDocument document,
  int pageNumber, {
  PhotoPageAnalysis? previous,
  List<String> priority = const [],
  int maxImages = 8,
  int maxPixels = 8000000,
  Duration timeBudget = const Duration(milliseconds: 20),
}) {
  final modulePath = Pdfrx.pdfiumModulePath;
  return document.useNativeDocumentHandle(
    (handle) => _analyzeOffThread(
      handle,
      pageNumber,
      modulePath,
      previous,
      priority,
      maxImages,
      maxPixels,
      timeBudget,
    ),
  );
}

// Separate scope prevents the isolate closure from capturing the document/lease.
Future<PhotoPageAnalysis> _analyzeOffThread(
  int handle,
  int page,
  String? path,
  PhotoPageAnalysis? previous,
  List<String> priority,
  int maxImages,
  int maxPixels,
  Duration timeBudget,
) => Isolate.run(
  () => inspectPhotoPage(
    handle,
    page,
    path,
    previous: previous,
    priority: priority,
    maxImages: maxImages,
    maxPixels: maxPixels,
    timeBudget: timeBudget,
  ),
);

/// Call only while PDFium is locked. The first batch inventories the page; each
/// continuation decodes a bounded portion, re-resolving paths in a fresh page.
PhotoPageAnalysis inspectPhotoPage(
  int handle,
  int pageNumber,
  String? path, {
  PhotoPageAnalysis? previous,
  List<String> priority = const [],
  int maxImages = 8,
  int maxPixels = 8000000,
  Duration timeBudget = const Duration(milliseconds: 20),
}) {
  if (previous?.isComplete ?? false) return previous!;
  final watch = Stopwatch()..start();
  final api = getPdfium(modulePath: path);
  final page = api.FPDF_LoadPage(
    Pointer<fpdf_document_t__>.fromAddress(handle),
    pageNumber - 1,
  );
  if (page == nullptr) {
    return PhotoPageAnalysis.failed(previous, 'page-unavailable');
  }
  try {
    if (previous != null) {
      final results = previous.candidates.toList();
      final pending = previous._pending.toList();
      final rank = {for (var i = 0; i < priority.length; i++) priority[i]: i};
      pending.sort((a, b) {
        final order = (rank[results[a.index].objectId] ?? priority.length)
            .compareTo(rank[results[b.index].objectId] ?? priority.length);
        return order != 0 ? order : a.index.compareTo(b.index);
      });
      var completed = 0, pixels = 0;
      for (final work in pending) {
        // Always admit one bounded image, even when page loading consumed the
        // time slice or this image exceeds the batch's target pixel allowance.
        // Otherwise a costly image could remain pending forever.
        if (completed > 0 &&
            (completed >= maxImages ||
                pixels + work.pixels > maxPixels ||
                watch.elapsed > timeBudget)) {
          break;
        }
        final before = results[work.index];
        final object = _resolveImage(api, page, before.objectPath);
        String reason;
        PhotoClassification? classification;
        if (object == nullptr) {
          reason = 'image-unavailable';
        } else {
          final image = work.bind(object, before.objectPath);
          pixels += work.pixels;
          final rendered = api.FPDFImageObj_GetRenderedBitmap(
            Pointer<fpdf_document_t__>.fromAddress(handle),
            page,
            object,
          );
          if (rendered == nullptr) {
            reason = 'opacity-unavailable';
          } else {
            bool opaque;
            try {
              opaque = _isOpaque(api, rendered, image);
            } finally {
              api.FPDFBitmap_Destroy(rendered);
            }
            if (!opaque) {
              reason = 'mask-or-transparency';
            } else {
              final bitmap = api.FPDFImageObj_GetBitmap(object);
              if (bitmap == nullptr) {
                reason = 'decode-failed';
              } else {
                try {
                  final sample = _sampleBitmap(api, bitmap, image);
                  classification = sample == null
                      ? null
                      : classifyPhoto(sample);
                  reason = classification?.reason ?? 'unsupported-bitmap';
                } finally {
                  api.FPDFBitmap_Destroy(bitmap);
                }
              }
            }
          }
        }
        results[work.index] = PhotoCandidate(
          before.objectIndex,
          reason,
          region: before.region,
          objectPath: before.objectPath,
          classification: classification,
        );
        completed++;
      }
      return PhotoPageAnalysis._(
        results,
        pending.skip(completed).toList(),
        elapsedMicroseconds:
            previous.elapsedMicroseconds + watch.elapsedMicroseconds,
        batchDecodedImages: completed,
        batchDecodedPixels: pixels,
      );
    }
    return using((arena) {
      final box = arena<FS_RECTF>();
      if (api.FPDF_GetPageBoundingBox(page, box) == 0) {
        return const PhotoPageAnalysis(fallback: 'unknown-page-box');
      }
      final crop = PhotoRegion(
        box.ref.left,
        box.ref.bottom,
        box.ref.right,
        box.ref.top,
      );
      if (!crop.area.isFinite || crop.area <= 0) {
        return const PhotoPageAnalysis(fallback: 'invalid-page-box');
      }
      final tree = _PageObjects(api, arena);
      tree.walk(page, null, const [], const _Transform.identity(), crop, null);
      PhotoRegion cropRelative(PhotoRegion r) => PhotoRegion(
        r.left - crop.left,
        r.bottom - crop.bottom,
        r.right - crop.left,
        r.top - crop.bottom,
      );
      final images = tree.leaves
          .where((o) => o.type == FPDF_PAGEOBJ_IMAGE)
          .toList();
      PhotoCandidate candidate(_Object image, String reason) => PhotoCandidate(
        image.path.first,
        reason,
        objectPath: image.path,
        region: cropRelative(image.visible),
      );
      if (tree.fallback != null) {
        return PhotoPageAnalysis(
          fallback: tree.fallback,
          candidates: List.unmodifiable([
            for (final image in images) candidate(image, tree.fallback!),
          ]),
          elapsedMicroseconds: watch.elapsedMicroseconds,
        );
      }
      final candidates = <PhotoCandidate>[];
      final pending = <_PendingImage>[];
      final width = arena<UnsignedInt>(), height = arena<UnsignedInt>();
      for (final original in images) {
        var image = original;
        final object = image.handle;
        final rect = image.visible;
        String? reject = image.reject;
        if (tree.hasTextClip) {
          // The public clip-path API omits text clipping. Do not mistake its
          // geometric subpaths for the complete clip, even inside a Form.
          reject = 'text-clip';
        } else if (reject == null) {
          if (rect.right - rect.left < 24 || rect.top - rect.bottom < 24) {
            reject = 'small-or-outside-page';
          } else if (rect.area / crop.area >= .65) {
            reject = 'scan-or-full-page-image';
          } else if (!image.transform.isRectangular ||
              !image.localTransform.isRectangular) {
            reject = 'non-rectangular-transform';
          } else {
            // Form containers are not paint operations. Earlier leaves can be
            // covered by an image that passes opacity checks; later labels cannot.
            var clear = rect;
            for (final later in tree.leaves.skip(image.order + 1)) {
              final remaining = tree.clearRegion(later, clear);
              if (remaining == null) {
                reject = 'overlapping-page-content';
                break;
              }
              clear = remaining;
            }
            image = image.withVisible(clear);
            if (reject == null &&
                (clear.right - clear.left < 24 ||
                    clear.top - clear.bottom < 24)) {
              reject = 'small-or-outside-page';
            }
          }
        }
        if (reject == null) {
          if (api.FPDFImageObj_GetImagePixelSize(object, width, height) == 0) {
            reject = 'image-size-unavailable';
          } else if (width.value < 64 || height.value < 64) {
            reject = 'small-image';
          } else if (width.value > 4000000 ||
              height.value > 4000000 ||
              width.value * height.value > 4000000) {
            reject = 'image-pixel-budget';
          }
        }
        if (reject != null) {
          candidates.add(candidate(image, reject));
          continue;
        }
        // GetRenderedBitmap includes intrinsic image masks, unlike GetBitmap.
        // Its allocation is based on the object's LOCAL matrix, not the parent
        // Form or source pixel dimensions. Bound both allocations before calling.
        final extentWidth = math.sqrt(
          image.localTransform.a * image.localTransform.a +
              image.localTransform.c * image.localTransform.c,
        );
        final extentHeight = math.sqrt(
          image.localTransform.b * image.localTransform.b +
              image.localTransform.d * image.localTransform.d,
        );
        // Check doubles before converting/multiplying bounded integers.
        if (!extentWidth.isFinite ||
            !extentHeight.isFinite ||
            extentWidth <= 0 ||
            extentHeight <= 0 ||
            extentWidth > 4000000 ||
            extentHeight > 4000000) {
          candidates.add(candidate(image, 'rendered-image-budget'));
          continue;
        }
        final renderedPixels = extentWidth.ceil() * extentHeight.ceil();
        if (renderedPixels > 4000000) {
          candidates.add(candidate(image, 'rendered-image-budget'));
          continue;
        }
        pending.add(
          _PendingImage(
            candidates.length,
            image.visible,
            image.transform,
            image.localTransform,
            image.parentTransform,
            width.value * height.value + renderedPixels,
          ),
        );
        candidates.add(candidate(image, 'pending'));
      }
      return PhotoPageAnalysis._(
        candidates,
        pending,
        elapsedMicroseconds: watch.elapsedMicroseconds,
      );
    });
  } finally {
    api.FPDF_ClosePage(page);
  }
}

FPDF_PAGEOBJECT _resolveImage(PDFium api, FPDF_PAGE page, List<int> path) {
  if (path.isEmpty ||
      path.first < 0 ||
      path.first >= api.FPDFPage_CountObjects(page)) {
    return nullptr;
  }
  var object = api.FPDFPage_GetObject(page, path.first);
  for (final index in path.skip(1)) {
    if (object == nullptr ||
        api.FPDFPageObj_GetType(object) != FPDF_PAGEOBJ_FORM ||
        index < 0 ||
        index >= api.FPDFFormObj_CountObjects(object)) {
      return nullptr;
    }
    object = api.FPDFFormObj_GetObject(object, index);
  }
  return object != nullptr &&
          api.FPDFPageObj_GetType(object) == FPDF_PAGEOBJ_IMAGE
      ? object
      : nullptr;
}

/// No FFI pointers or source pixels survive a batch.
class _PendingImage {
  const _PendingImage(
    this.index,
    this.visible,
    this.transform,
    this.localTransform,
    this.parentTransform,
    this.pixels,
  );
  final int index, pixels;
  final PhotoRegion visible;
  final _Transform transform, localTransform, parentTransform;
  _Object bind(FPDF_PAGEOBJECT handle, List<int> path) => _Object(
    handle,
    FPDF_PAGEOBJ_IMAGE,
    path,
    0,
    visible,
    transform,
    localTransform,
    parentTransform,
    null,
  );
}

Uint8List? _sampleBitmap(PDFium api, FPDF_BITMAP bitmap, _Object image) {
  final width = api.FPDFBitmap_GetWidth(bitmap);
  final height = api.FPDFBitmap_GetHeight(bitmap);
  final stride = api.FPDFBitmap_GetStride(bitmap);
  final format = api.FPDFBitmap_GetFormat(bitmap);
  final channels = switch (format) {
    FPDFBitmap_Gray => 1,
    FPDFBitmap_BGR => 3,
    FPDFBitmap_BGRx || FPDFBitmap_BGRA => 4,
    _ => 0,
  };
  final buffer = api.FPDFBitmap_GetBuffer(bitmap);
  if (channels == 0 ||
      width < 64 ||
      height < 64 ||
      width * height > 4000000 ||
      stride < width * channels ||
      stride * height > 20000000 ||
      buffer == nullptr) {
    return null;
  }
  final bytes = buffer.cast<Uint8>().asTypedList(stride * height);
  final sample = Uint8List(64 * 64 * 3);
  final inverse = image.transform.inverse;
  final rect = image.visible;
  for (var y = 0; y < 64; y++) {
    for (var x = 0; x < 64; x++) {
      // Sample only the visible crop, in page orientation. Image pixels use
      // top-down rows, whereas the PDF image unit square has y increasing up.
      final point = inverse.point(
        rect.left + (x + .5) * (rect.right - rect.left) / 64,
        rect.top - (y + .5) * (rect.top - rect.bottom) / 64,
      );
      final sx = (point.$1 * width).floor().clamp(0, width - 1);
      final sy = ((1 - point.$2) * height).floor().clamp(0, height - 1);
      final source = sy * stride + sx * channels;
      if (format == FPDFBitmap_BGRA && bytes[source + 3] != 255) return null;
      final target = (y * 64 + x) * 3;
      sample[target] = bytes[source + (channels == 1 ? 0 : 2)];
      sample[target + 1] = bytes[source + (channels == 1 ? 0 : 1)];
      sample[target + 2] = bytes[source];
    }
  }
  return sample;
}

PhotoRegion _intersect(PhotoRegion a, PhotoRegion b) => PhotoRegion(
  math.max(a.left, b.left),
  math.max(a.bottom, b.bottom),
  math.min(a.right, b.right),
  math.min(a.top, b.top),
);

class _Transform {
  const _Transform(this.a, this.b, this.c, this.d, this.e, this.f);
  const _Transform.identity() : this(1, 0, 0, 1, 0, 0);
  factory _Transform.fromNative(FS_MATRIX m) =>
      _Transform(m.a, m.b, m.c, m.d, m.e, m.f);
  final double a, b, c, d, e, f;
  bool get isValid =>
      [a, b, c, d, e, f].every((v) => v.isFinite) &&
      (a * d - b * c).abs() > 1e-12;
  bool get isRectangular =>
      isValid &&
      ((b.abs() < .001 && c.abs() < .001) ||
          (a.abs() < .001 && d.abs() < .001));
  (double, double) point(double x, double y) =>
      (a * x + c * y + e, b * x + d * y + f);
  _Transform compose(_Transform child) => _Transform(
    a * child.a + c * child.b,
    b * child.a + d * child.b,
    a * child.c + c * child.d,
    b * child.c + d * child.d,
    a * child.e + c * child.f + e,
    b * child.e + d * child.f + f,
  );
  _Transform get inverse {
    final det = a * d - b * c;
    return _Transform(
      d / det,
      -b / det,
      -c / det,
      a / det,
      (c * f - d * e) / det,
      (b * e - a * f) / det,
    );
  }

  PhotoRegion rect(PhotoRegion r) {
    final points = [
      point(r.left, r.bottom),
      point(r.left, r.top),
      point(r.right, r.bottom),
      point(r.right, r.top),
    ];
    return PhotoRegion(
      points.map((p) => p.$1).reduce(math.min),
      points.map((p) => p.$2).reduce(math.min),
      points.map((p) => p.$1).reduce(math.max),
      points.map((p) => p.$2).reduce(math.max),
    );
  }
}

class _Object {
  _Object(
    this.handle,
    this.type,
    this.path,
    this.order,
    this.visible,
    this.transform,
    this.localTransform,
    this.parentTransform,
    this.reject,
  );
  final FPDF_PAGEOBJECT handle;
  final int type, order;
  final List<int> path;
  final PhotoRegion visible;
  final _Transform transform, localTransform, parentTransform;
  final String? reject;
  _Object withVisible(PhotoRegion region) => _Object(
    handle,
    type,
    path,
    order,
    region,
    transform,
    localTransform,
    parentTransform,
    reject,
  );
}

/// A flattened display list in PDF paint order. No borrowed handles escape the
/// page lifetime; Forms contribute inherited state, not overlapping rectangles.
class _PageObjects {
  _PageObjects(this.api, this.arena);
  final PDFium api;
  final Arena arena;
  final leaves = <_Object>[];
  int visited = 0;
  bool hasTextClip = false;
  String? fallback;

  void walk(
    FPDF_PAGE page,
    FPDF_PAGEOBJECT? form,
    List<int> path,
    _Transform parent,
    PhotoRegion inheritedClip,
    String? inheritedReject,
  ) {
    if (path.length > 16) {
      fallback = 'form-depth-budget';
      return;
    }
    final count = form == null
        ? api.FPDFPage_CountObjects(page)
        : api.FPDFFormObj_CountObjects(form);
    if (count < 0 || count > 2000 - visited) {
      fallback = 'object-budget';
      return;
    }
    // Allocate once per nesting level, not once per object.
    final coords = arena<Float>(4);
    final matrix = arena<FS_MATRIX>();
    for (var i = 0; i < count && fallback == null; i++) {
      if (++visited > 2000) {
        fallback = 'object-budget';
        return;
      }
      final object = form == null
          ? api.FPDFPage_GetObject(page, i)
          : api.FPDFFormObj_GetObject(form, i);
      if (object == nullptr ||
          api.FPDFPageObj_GetBounds(
                object,
                coords,
                coords + 1,
                coords + 2,
                coords + 3,
              ) ==
              0) {
        fallback = 'unknown-object-bounds';
        return;
      }
      if (!List.generate(4, (j) => coords[j]).every((v) => v.isFinite)) {
        fallback = 'invalid-object-bounds';
        return;
      }
      final type = api.FPDFPageObj_GetType(object);
      final objectPath = List<int>.unmodifiable([...path, i]);
      var local = const _Transform.identity();
      if (type == FPDF_PAGEOBJ_FORM ||
          type == FPDF_PAGEOBJ_IMAGE ||
          type == FPDF_PAGEOBJ_PATH) {
        if (api.FPDFPageObj_GetMatrix(object, matrix) == 0) {
          fallback = 'unknown-object-transform';
          return;
        }
        local = _Transform.fromNative(matrix.ref);
        if (!local.isValid) {
          fallback = 'invalid-object-transform';
          return;
        }
      }
      final transform = parent.compose(local);
      if (!transform.isValid) {
        fallback = 'invalid-object-transform';
        return;
      }
      var reject = inheritedReject;
      if (api.FPDFPageObj_HasTransparency(object) != 0) {
        reject ??= type == FPDF_PAGEOBJ_FORM
            ? 'form-transparency'
            : 'transparency';
      }
      final (clip, clipReason) = _clip(object, parent, inheritedClip);
      reject ??= clipReason;
      if (type == FPDF_PAGEOBJ_FORM) {
        walk(page, object, objectPath, transform, clip, reject);
      } else {
        if (type == FPDF_PAGEOBJ_TEXT) {
          final mode = api.FPDFTextObj_GetTextRenderMode(object).value;
          if (mode < 0 || mode >= 4) hasTextClip = true;
        }
        // Bounds already include the object's own transform, but not its
        // containing Forms. Applying the image matrix here would double it.
        final bounds = parent.rect(
          PhotoRegion(coords[0], coords[1], coords[2], coords[3]),
        );
        leaves.add(
          _Object(
            object,
            type,
            objectPath,
            leaves.length,
            _intersect(bounds, clip),
            transform,
            local,
            parent,
            reject,
          ),
        );
      }
    }
  }

  final _filledPaths = <int, _FilledPath?>{};

  PhotoRegion? clearRegion(_Object object, PhotoRegion rect) {
    if (!rect.overlaps(object.visible)) return rect;
    if (object.type != FPDF_PAGEOBJ_PATH) return null;
    // Illustrator-style frames are often filled polygons with a hole, not
    // strokes. Bounding boxes alone incorrectly treat that hole as painted.
    final path = _filledPaths.putIfAbsent(
      object.handle.address,
      () => _filledPath(object),
    );
    if (path == null) return null;
    if (!path.mayPaint(rect)) return rect;
    // Frame edges can meet or slightly enter the image. Preserve only a
    // verified clear interior, leaving a one-point margin for antialiasing.
    final inner = PhotoRegion(
      rect.left + 1,
      rect.bottom + 1,
      rect.right - 1,
      rect.top - 1,
    );
    if (inner.right <= inner.left ||
        inner.top <= inner.bottom ||
        path.mayPaint(inner)) {
      return null;
    }
    return inner;
  }

  _FilledPath? _filledPath(_Object object) {
    final fill = arena<Int>(), stroke = arena<Int>();
    if (api.FPDFPath_GetDrawMode(object.handle, fill, stroke) == 0 ||
        stroke.value != 0 ||
        (fill.value != 1 && fill.value != 2)) {
      return null;
    }
    final count = api.FPDFPath_CountSegments(object.handle);
    if (count < 3 || count > 256) return null;
    final x = arena<Float>(), y = arena<Float>();
    final contours = <List<(double, double)>>[];
    var contour = <(double, double)>[];
    for (var i = 0; i < count; i++) {
      final segment = api.FPDFPath_GetPathSegment(object.handle, i);
      if (segment == nullptr ||
          api.FPDFPathSegment_GetPoint(segment, x, y) == 0) {
        return null;
      }
      final type = api.FPDFPathSegment_GetType(segment);
      if (type == FPDF_SEGMENT_MOVETO) {
        if (contour.isNotEmpty) contours.add(contour);
        contour = [];
      } else if (type != FPDF_SEGMENT_LINETO || contour.isEmpty) {
        return null; // Curves and stroke joins stay conservative.
      }
      final point = object.transform.point(x.value, y.value);
      if (!point.$1.isFinite || !point.$2.isFinite) return null;
      contour.add(point);
      if (api.FPDFPathSegment_GetClose(segment) != 0) {
        contours.add(contour);
        contour = [];
      }
    }
    if (contour.isNotEmpty) contours.add(contour); // Fill implicitly closes.
    if (contours.any((c) => c.length < 3)) return null;
    return _FilledPath(contours, fill.value == 1);
  }

  (PhotoRegion, String?) _clip(
    FPDF_PAGEOBJECT object,
    _Transform parent,
    PhotoRegion inherited,
  ) {
    final clip = api.FPDFPageObj_GetClipPath(object);
    if (clip == nullptr) return (inherited, 'unknown-clip');
    final count = api.FPDFClipPath_CountPaths(clip);
    if (count == -1) return (inherited, null); // borrowed, unreferenced wrapper
    if (count <= 0 || count > 8) return (inherited, 'complex-clip');
    var result = inherited;
    final x = arena<Float>();
    final y = arena<Float>();
    for (var i = 0; i < count; i++) {
      final n = api.FPDFClipPath_CountPathSegments(clip, i);
      if (n < 4 || n > 5) return (inherited, 'complex-clip');
      final points = <(double, double)>[];
      for (var j = 0; j < n; j++) {
        final segment = api.FPDFClipPath_GetPathSegment(clip, i, j);
        if (segment == nullptr ||
            api.FPDFPathSegment_GetType(segment) !=
                (j == 0 ? FPDF_SEGMENT_MOVETO : FPDF_SEGMENT_LINETO) ||
            api.FPDFPathSegment_GetPoint(segment, x, y) == 0 ||
            (j < n - 1 && api.FPDFPathSegment_GetClose(segment) != 0)) {
          return (inherited, 'complex-clip');
        }
        final p = parent.point(x.value, y.value);
        if (!p.$1.isFinite || !p.$2.isFinite) {
          return (inherited, 'complex-clip');
        }
        points.add(p);
      }
      bool near((double, double) a, (double, double) b) =>
          (a.$1 - b.$1).abs() < .001 && (a.$2 - b.$2).abs() < .001;
      if (points.length == 5) {
        if (!near(points.first, points.last)) {
          return (inherited, 'complex-clip');
        }
        points.removeLast();
      }
      for (var j = 0; j < 4; j++) {
        final a = points[j], b = points[(j + 1) % 4];
        if (near(a, b) ||
            ((a.$1 - b.$1).abs() >= .001 && (a.$2 - b.$2).abs() >= .001)) {
          return (inherited, 'complex-clip');
        }
      }
      final rect = PhotoRegion(
        points.map((p) => p.$1).reduce(math.min),
        points.map((p) => p.$2).reduce(math.min),
        points.map((p) => p.$1).reduce(math.max),
        points.map((p) => p.$2).reduce(math.max),
      );
      final corners = [
        (rect.left, rect.bottom),
        (rect.left, rect.top),
        (rect.right, rect.bottom),
        (rect.right, rect.top),
      ];
      if (!corners.every((c) => points.where((p) => near(c, p)).length == 1)) {
        return (inherited, 'complex-clip');
      }
      result = _intersect(result, rect);
    }
    return (result, null);
  }
}

class _FilledPath {
  _FilledPath(this.contours, this.evenOdd);
  final List<List<(double, double)>> contours;
  final bool evenOdd;

  bool mayPaint(PhotoRegion rect) {
    final x = (rect.left + rect.right) / 2;
    final y = (rect.bottom + rect.top) / 2;
    var winding = 0;
    for (final contour in contours) {
      for (var i = 0; i < contour.length; i++) {
        final a = contour[i], b = contour[(i + 1) % contour.length];
        // If an edge could enter the image, no inference from the center is
        // safe. An expanded AABB is deliberately conservative for diagonals.
        if (rect.overlaps(
          PhotoRegion(
            math.min(a.$1, b.$1) - .001,
            math.min(a.$2, b.$2) - .001,
            math.max(a.$1, b.$1) + .001,
            math.max(a.$2, b.$2) + .001,
          ),
        )) {
          return true;
        }
        final side = (b.$1 - a.$1) * (y - a.$2) - (x - a.$1) * (b.$2 - a.$2);
        if (a.$2 <= y && b.$2 > y && side > 0) winding++;
        if (a.$2 > y && b.$2 <= y && side < 0) winding--;
      }
    }
    return evenOdd ? winding.isOdd : winding != 0;
  }
}

bool _isOpaque(PDFium api, FPDF_BITMAP bitmap, _Object image) {
  final width = api.FPDFBitmap_GetWidth(bitmap);
  final height = api.FPDFBitmap_GetHeight(bitmap);
  final stride = api.FPDFBitmap_GetStride(bitmap);
  final buffer = api.FPDFBitmap_GetBuffer(bitmap);
  if (api.FPDFBitmap_GetFormat(bitmap) != FPDFBitmap_BGRA ||
      width <= 0 ||
      height <= 0 ||
      width * height > 4000000 ||
      stride < width * 4 ||
      stride * height > 20000000 ||
      buffer == nullptr) {
    return false;
  }
  final local = image.parentTransform.inverse.rect(image.visible);
  final bounds = image.localTransform.rect(const PhotoRegion(0, 0, 1, 1));
  // PDFium renders the transformed image into a bitmap of its local extent.
  // Inspect every covered pixel, not just the classifier's 64x64 sample.
  final left =
      ((local.left - bounds.left) / (bounds.right - bounds.left) * width)
          .floor()
          .clamp(0, width - 1);
  final right =
      ((local.right - bounds.left) / (bounds.right - bounds.left) * width)
          .ceil()
          .clamp(left + 1, width);
  final top = ((bounds.top - local.top) / (bounds.top - bounds.bottom) * height)
      .floor()
      .clamp(0, height - 1);
  final bottom =
      ((bounds.top - local.bottom) / (bounds.top - bounds.bottom) * height)
          .ceil()
          .clamp(top + 1, height);
  final bytes = buffer.cast<Uint8>().asTypedList(stride * height);
  for (var y = top; y < bottom; y++) {
    for (var x = left; x < right; x++) {
      if (bytes[y * stride + x * 4 + 3] != 255) return false;
    }
  }
  return true;
}
