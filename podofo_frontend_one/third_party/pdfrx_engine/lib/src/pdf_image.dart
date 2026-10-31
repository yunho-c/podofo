import 'dart:typed_data';

import 'pdf_page.dart';

/// Image rendered from PDF page.
///
/// Please note that the image created must be disposed after use by calling [dispose].
/// See [PdfPage.render].
abstract class PdfImage {
  /// Number of pixels in horizontal direction.
  int get width;

  /// Number of pixels in vertical direction.
  int get height;

  /// BGRA8888 Raw pixel data.
  Uint8List get pixels;

  /// Dispose the image.
  void dispose();

  /// Create [PdfImage] from BGRA pixel data.
  ///
  /// [bgraPixels] is the raw pixel data in BGRA8888 format.
  /// [width] and [height] specify the dimensions of the image.
  ///
  /// The size of [bgraPixels] must be equal to `width * height * 4`.
  /// Returns the created [PdfImage].
  static PdfImage createFromBgraData(Uint8List bgraPixels, {required int width, required int height}) {
    return _PdfImageBgraRaw(width, height, bgraPixels);
  }
}

class _PdfImageBgraRaw implements PdfImage {
  _PdfImageBgraRaw(this.width, this.height, this.pixels);

  @override
  final int width;

  @override
  final int height;

  @override
  final Uint8List pixels;

  @override
  void dispose() {}
}

/// Exclusive native BGRA allocation for an immutable foreign reader.
///
/// Advanced API: [address] is valid only while this lease is retained and not
/// released. Do not mutate the allocation, expose writable views, transfer the
/// lease between isolates, or release it until every foreign reader has stopped.
/// No PDF document/page handle is retained. Explicit [release] is preferred;
/// native implementations may use a finalizer as a last-resort leak fallback.
abstract interface class PdfNativeImageLease {
  int get width;
  int get height;
  int get rowBytes;
  int get initializedBytes;

  /// Requested allocation size, excluding allocator bookkeeping.
  int get retainedBytes;
  int get address;
  bool get isReleased;

  /// Free once, after the last reader. Repeated release is harmless.
  void release();
}

/// Capability implemented by renderers that can transfer exclusive storage.
abstract interface class PdfNativeImageOwner implements PdfImage {
  /// Return null when a writable pixel view has already escaped. A successful
  /// transfer invalidates image pixel access; image disposal becomes a no-op.
  /// Calling on an already disposed/transferred image throws [StateError].
  PdfNativeImageLease? tryTransferNativeImage();
}

extension PdfImageNativeOwnership on PdfImage {
  /// Transfer newly rendered storage without copying when supported and when
  /// [PdfImage.pixels] has never been read. Otherwise return null for copying.
  PdfNativeImageLease? tryTakeNativeLease() {
    final image = this;
    return image is PdfNativeImageOwner ? image.tryTransferNativeImage() : null;
  }
}
