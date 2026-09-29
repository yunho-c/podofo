import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:podofo_one/src/workers/thumbnail_worker.dart';
import 'package:podofo_one/src/workers/open_graph_worker.dart';

void main() {
  test('thumbnail LRU bounds bytes and entries and refreshes access order', () {
    final cache = ThumbnailCache(maxBytes: 6, maxEntries: 2);
    cache.put('a', Uint8List(3));
    cache.put('b', Uint8List(3));
    expect(cache.get('a'), isNotNull);
    cache.put('c', Uint8List(3));
    expect(cache.get('b'), isNull);
    expect(cache.bytes, 6);
    cache.put('large', Uint8List(7));
    expect(cache.length, 2);
    cache.put('a', Uint8List(1));
    expect(cache.bytes, 4);
  });
  test(
    'link destinations are inert and only explicit web links can launch',
    () {
      for (final url in [
        'file:///C:/secret',
        'javascript:alert(1)',
        'data:text/html,x',
        'https://user:pass@example.com',
      ]) {
        expect(canOpenExternalLink(Uri.parse(url)), false);
      }
      final uri = Uri.parse('https://example.com/a?b=c#d');
      expect(linkPreviewLabel(uri), uri.toString());
      expect(canOpenExternalLink(uri), true);
    },
  );
}
