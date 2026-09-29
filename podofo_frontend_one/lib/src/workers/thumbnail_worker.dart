import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;
import 'package:pdfrx/pdfrx.dart';
import 'package:synchronized/synchronized.dart';

import '../services/pdf_session.dart';

/// A bounded LRU. Thumbnails are disposable; no stale path-keyed disk records.
class ThumbnailCache {
  ThumbnailCache({this.maxBytes = 8 * 1024 * 1024, this.maxEntries = 128});
  final int maxBytes, maxEntries;
  final _items = <String, Uint8List>{};
  int bytes = 0;
  int get length => _items.length;
  Uint8List? get(String key) {
    final value = _items.remove(key);
    if (value != null) _items[key] = value;
    return value;
  }

  void put(String key, Uint8List value) {
    final previous = _items.remove(key);
    if (previous != null) bytes -= previous.length;
    if (value.length > maxBytes) return;
    _items[key] = value;
    bytes += value.length;
    while (bytes > maxBytes || _items.length > maxEntries) {
      bytes -= _items.remove(_items.keys.first)!.length;
    }
  }
}

final thumbnailCacheProvider = Provider((ref) => ThumbnailCache());
final _renderQueueProvider = Provider((ref) => Lock());
typedef ThumbnailRequest = ({
  PdfSession session,
  int revision,
  int page,
  int pixelWidth,
  int pixelHeight,
});

final thumbnailProvider = FutureProvider.autoDispose
    .family<Uint8List?, ThumbnailRequest>((ref, request) async {
      final cache = ref.read(thumbnailCacheProvider);
      final key =
          '${request.session.cacheKey}:${request.page}:'
          '${request.pixelWidth}x${request.pixelHeight}';
      final cached = cache.get(key);
      if (cached != null) return cached;
      var cancelled = false;
      PdfPageRenderCancellationToken? token;
      ref.onDispose(() {
        cancelled = true;
        token?.cancel();
      });
      return ref.read(_renderQueueProvider).synchronized(() async {
        if (cancelled || request.session.lease.isClosed) return null;
        return request.session.lease.use((pdf) async {
          if (cancelled || request.revision != request.session.revision) {
            return null;
          }
          final page = pdf.pages[request.page - 1];
          final scale = math.min(
            request.pixelWidth.clamp(64, 1024) / page.width,
            request.pixelHeight.clamp(64, 1536) / page.height,
          );
          token = page.createCancellationToken();
          final image = await page.render(
            fullWidth: page.width * scale,
            fullHeight: page.height * scale,
            cancellationToken: token,
          );
          if (image == null) return null;
          try {
            if (cancelled) return null;
            final bytes = await compute(_encodeThumbnail, (
              width: image.width,
              height: image.height,
              pixels: Uint8List.fromList(image.pixels),
            ));
            if (cancelled || request.revision != request.session.revision) {
              return null;
            }
            cache.put(key, bytes);
            return bytes;
          } finally {
            image.dispose();
          }
        });
      });
    });

Uint8List _encodeThumbnail(({int width, int height, Uint8List pixels}) data) {
  final image = img.Image.fromBytes(
    width: data.width,
    height: data.height,
    bytes: data.pixels.buffer,
    order: img.ChannelOrder.bgra,
  );
  return img.encodeJpg(image, quality: 70);
}
