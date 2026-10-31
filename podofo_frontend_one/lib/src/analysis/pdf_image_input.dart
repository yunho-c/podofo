import 'dart:ffi';

import 'package:pdfrx/pdfrx.dart';
import 'package:podoco/podoco.dart' as podoco;

/// Optional aggregate diagnostics for the renderer-to-Podoco handoff only.
/// Counters do not include rendering, preprocessing, tensors or allocator overhead.
class AnalysisImageTransfers {
  int _leased = 0, _released = 0, _rejected = 0, _copied = 0;
  int _liveBytes = 0, _peakBytes = 0, _copiedBytes = 0, _handoffMicros = 0;
  int get leased => _leased;
  int get released => _released;
  int get rejected => _rejected;
  int get copied => _copied;
  int get liveBytes => _liveBytes;
  int get peakBytes => _peakBytes;

  /// Bytes copied on each of the staging and Rust-owned copy paths.
  int get copiedBytes => _copiedBytes;
  int get handoffMicroseconds => _handoffMicros;
}

/// Own a fresh, exclusively rendered image. The caller still disposes the
/// PdfImage wrapper; a successful lease makes that disposal harmless. Native
/// reads retain the lease until Podoco's independent release acknowledgement.
podoco.PageImage analysisImageInput(
  PdfImage image, {
  required int byteBudget,
  bool preferNativeLease = true,
  AnalysisImageTransfers? transfers,
}) {
  final timer = Stopwatch()..start();
  try {
    final descriptor = podoco.ImageDescriptor(
      width: image.width,
      height: image.height,
      rowStride: image.width * 4,
      format: podoco.PixelFormat.bgra8,
      alpha: podoco.AlphaMode.opaque,
    );
    final lease = preferNativeLease ? image.tryTakeNativeLease() : null;
    if (lease != null) {
      transfers?._leased++;
      if (transfers != null) {
        transfers._liveBytes += lease.retainedBytes;
        if (transfers._liveBytes > transfers._peakBytes) {
          transfers._peakBytes = transfers._liveBytes;
        }
      }
      void release() {
        lease.release();
        if (transfers != null) {
          transfers._released++;
          transfers._liveBytes -= lease.retainedBytes;
        }
      }

      try {
        return podoco.PageImage.importNative(
          descriptor: descriptor,
          pointer: Pointer<Uint8>.fromAddress(lease.address),
          initializedBytes: lease.initializedBytes,
          retainedBytes: lease.retainedBytes,
          byteBudget: byteBudget,
          onRelease: release,
        );
      } catch (_) {
        // Rejection leaves renderer ownership with this caller.
        transfers?._rejected++;
        release();
        rethrow;
      }
    }
    final copied = podoco.PageImage.copy(
      descriptor: descriptor,
      bytes: image.pixels,
      byteBudget: byteBudget,
    );
    if (transfers != null) {
      transfers._copied++;
      transfers._copiedBytes += image.width * image.height * 4;
    }
    return copied;
  } finally {
    if (transfers != null) {
      transfers._handoffMicros += timer.elapsedMicroseconds;
    }
  }
}
