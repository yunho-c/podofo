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
  const PhotoCandidate(this.objectIndex, this.reason, {this.classification});
  final int objectIndex;
  final String reason;
  final PhotoClassification? classification;
}

class PhotoPageAnalysis {
  const PhotoPageAnalysis({
    this.regions = const [],
    this.candidates = const [],
    this.fallback,
    this.elapsedMicroseconds = 0,
  });
  final List<PhotoRegion> regions;
  final List<PhotoCandidate> candidates;
  final String? fallback;
  final int elapsedMicroseconds;
}

/// useNativeDocumentHandle suspends pdfrx's worker for the entire awaited action.
/// The caller must hold a lease/session read lock until this future completes.
/// The auxiliary isolate returns only detached data; it never calls pdfrx or
/// initializes/destroys the shared PDFium runtime.
Future<PhotoPageAnalysis> analyzePhotos(PdfDocument document, int pageNumber) {
  final modulePath = Pdfrx.pdfiumModulePath;
  return document.useNativeDocumentHandle(
    (handle) => _analyzeOffThread(handle, pageNumber, modulePath),
  );
}

// Separate scope prevents the isolate closure from capturing the document/lease.
Future<PhotoPageAnalysis> _analyzeOffThread(
  int handle,
  int page,
  String? path,
) => Isolate.run(() => inspectPhotoPage(handle, page, path));

/// Public for the native qualification harness. Call only while PDFium is locked.
PhotoPageAnalysis inspectPhotoPage(int handle, int pageNumber, String? path) {
  final watch = Stopwatch()..start();
  final api = getPdfium(modulePath: path);
  final page = api.FPDF_LoadPage(
    Pointer<fpdf_document_t__>.fromAddress(handle),
    pageNumber - 1,
  );
  if (page == nullptr) {
    return const PhotoPageAnalysis(fallback: 'page-unavailable');
  }
  try {
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
      final count = api.FPDFPage_CountObjects(page);
      if (count < 0 || count > 2000) {
        return const PhotoPageAnalysis(fallback: 'object-budget');
      }
      final bounds = <PhotoRegion>[];
      final objects = <FPDF_PAGEOBJECT>[];
      final imageIndices = <int>[];
      final coords = arena<Float>(4);
      for (var i = 0; i < count; i++) {
        final object = api.FPDFPage_GetObject(page, i);
        if (object == nullptr ||
            api.FPDFPageObj_GetBounds(
                  object,
                  coords,
                  coords + 1,
                  coords + 2,
                  coords + 3,
                ) ==
                0) {
          return const PhotoPageAnalysis(fallback: 'unknown-object-bounds');
        }
        final rect = PhotoRegion(coords[0], coords[1], coords[2], coords[3]);
        if (![
          rect.left,
          rect.bottom,
          rect.right,
          rect.top,
        ].every((v) => v.isFinite)) {
          return const PhotoPageAnalysis(fallback: 'invalid-object-bounds');
        }
        objects.add(object);
        bounds.add(rect);
        if (api.FPDFPageObj_GetType(object) == FPDF_PAGEOBJ_IMAGE) {
          imageIndices.add(i);
        }
      }
      if (imageIndices.length > 24) {
        return const PhotoPageAnalysis(fallback: 'image-budget');
      }
      final regions = <PhotoRegion>[];
      final candidates = <PhotoCandidate>[];
      final matrix = arena<FS_MATRIX>();
      final width = arena<UnsignedInt>();
      final height = arena<UnsignedInt>();
      var decodedPixels = 0;
      for (final index in imageIndices) {
        // Soft admission deadline; cannot interrupt a PDFium decode in progress.
        if (watch.elapsedMilliseconds > 80) {
          candidates.add(PhotoCandidate(index, 'time-budget'));
          continue;
        }
        final object = objects[index];
        final raw = bounds[index];
        final rect = PhotoRegion(
          math.max(raw.left, crop.left),
          math.max(raw.bottom, crop.bottom),
          math.min(raw.right, crop.right),
          math.min(raw.top, crop.top),
        );
        String? reject;
        if (rect.right - rect.left < 24 || rect.top - rect.bottom < 24) {
          reject = 'small-or-outside-page';
        } else if (rect.area / crop.area >= .65) {
          reject = 'scan-or-full-page-image';
        } else if (api.FPDFPageObj_HasTransparency(object) != 0) {
          reject = 'transparency';
        } else if (api.FPDFPageObj_GetMatrix(object, matrix) == 0 ||
            ![
              matrix.ref.a,
              matrix.ref.b,
              matrix.ref.c,
              matrix.ref.d,
            ].every((v) => v.isFinite) ||
            !((matrix.ref.b.abs() < .001 && matrix.ref.c.abs() < .001) ||
                (matrix.ref.a.abs() < .001 && matrix.ref.d.abs() < .001))) {
          reject = 'non-rectangular-transform';
        } else {
          final clip = api.FPDFPageObj_GetClipPath(object);
          // PDFium returns a borrowed empty wrapper for an unclipped object;
          // CountPaths is -1 when that wrapper has no reference (HasRef=false).
          // A referenced clip (including text-only clips with zero paths) is rejected.
          if (clip == nullptr || api.FPDFClipPath_CountPaths(clip) >= 0) {
            reject = 'explicit-clip';
          } else if (bounds.indexed.any(
            (entry) => entry.$1 != index && rect.overlaps(entry.$2),
          )) {
            // Includes text, vectors, other images and whole Form XObject bounds.
            // Even an underlay is rejected: no guessing about painting order.
            reject = 'overlapping-page-content';
          }
        }
        if (reject == null &&
            (api.FPDFImageObj_GetImagePixelSize(object, width, height) == 0 ||
                width.value < 64 ||
                height.value < 64 ||
                width.value * height.value > 4000000 ||
                decodedPixels + width.value * height.value > 8000000)) {
          reject = 'pixel-budget-or-small-image';
        }
        if (reject != null) {
          candidates.add(PhotoCandidate(index, reject));
          continue;
        }
        decodedPixels += width.value * height.value;
        final bitmap = api.FPDFImageObj_GetBitmap(object);
        if (bitmap == nullptr) {
          candidates.add(PhotoCandidate(index, 'decode-failed'));
          continue;
        }
        try {
          final sample = _sampleBitmap(api, bitmap);
          if (sample == null) {
            candidates.add(PhotoCandidate(index, 'unsupported-bitmap'));
            continue;
          }
          final classification = classifyPhoto(sample);
          candidates.add(
            PhotoCandidate(
              index,
              classification.reason,
              classification: classification,
            ),
          );
          if (classification.isLikelyPhoto) {
            regions.add(
              PhotoRegion(
                rect.left - crop.left,
                rect.bottom - crop.bottom,
                rect.right - crop.left,
                rect.top - crop.bottom,
              ),
            );
          }
        } finally {
          api.FPDFBitmap_Destroy(bitmap);
        }
      }
      return PhotoPageAnalysis(
        regions: List.unmodifiable(regions),
        candidates: List.unmodifiable(candidates),
        elapsedMicroseconds: watch.elapsedMicroseconds,
      );
    });
  } finally {
    api.FPDF_ClosePage(page);
  }
}

Uint8List? _sampleBitmap(PDFium api, FPDF_BITMAP bitmap) {
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
  for (var y = 0; y < 64; y++) {
    for (var x = 0; x < 64; x++) {
      final source =
          ((y + .5) * height / 64).floor() * stride +
          ((x + .5) * width / 64).floor() * channels;
      if (format == FPDFBitmap_BGRA && bytes[source + 3] != 255) return null;
      final target = (y * 64 + x) * 3;
      sample[target] = bytes[source + (channels == 1 ? 0 : 2)];
      sample[target + 1] = bytes[source + (channels == 1 ? 0 : 1)];
      sample[target + 2] = bytes[source];
    }
  }
  return sample;
}
