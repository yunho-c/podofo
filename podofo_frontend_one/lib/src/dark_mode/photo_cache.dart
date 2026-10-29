import 'dart:async';

import 'package:flutter/foundation.dart';

import 'photo_analysis.dart';

typedef PhotoLoader = Future<PhotoPageAnalysis> Function(int page);

/// One session/revision, bounded LRU, one admitted page at a time. Both failed
/// and successful analyses are cached; scrolling never retries a bad decode.
class PhotoAnalysisCache extends ChangeNotifier {
  PhotoAnalysisCache(
    this.load, {
    this.capacity = 64,
    this.settleDelay = const Duration(milliseconds: 150),
  });
  final PhotoLoader load;
  final int capacity;
  final Duration settleDelay;
  final _pages = <int, PhotoPageAnalysis>{};
  List<int> _visible = const [];
  Timer? _timer;
  bool _running = false;
  bool _disposed = false;
  int _epoch = 0;
  int analyses = 0;
  int cacheHits = 0;
  int totalMicroseconds = 0;

  int get length => _pages.length;
  bool get isIdle => !_running && !(_timer?.isActive ?? false);

  PhotoPageAnalysis? peek(int page) {
    final result = _pages.remove(page);
    if (result != null) {
      cacheHits++;
      _pages[page] = result;
    }
    return result;
  }

  void setVisiblePages(List<int> pages) {
    // At extreme zoom-out, keep a bounded working set without LRU thrashing.
    final bounded = pages.take(capacity).toList(growable: false);
    if (_disposed || listEquals(_visible, bounded)) return;
    _visible = bounded;
    _timer?.cancel();
    if (_visible.isNotEmpty) _timer = Timer(settleDelay, _drain);
  }

  void invalidate() {
    _epoch++;
    _pages.clear();
    _visible = const [];
    _timer?.cancel();
    // A read in flight owns its lease until completion; its result is discarded.
  }

  Future<void> _drain() async {
    if (_disposed || _running) return;
    _running = true;
    try {
      while (!_disposed) {
        final pending = _visible.where((p) => !_pages.containsKey(p));
        if (pending.isEmpty) break;
        final page = pending.first;
        final epoch = _epoch;
        final watch = Stopwatch()..start();
        PhotoPageAnalysis result;
        try {
          analyses++;
          result = await load(page);
        } catch (_) {
          result = const PhotoPageAnalysis(fallback: 'analysis-unavailable');
        }
        totalMicroseconds += watch.elapsedMicroseconds;
        if (_disposed) break;
        if (epoch == _epoch) {
          _pages[page] = result;
          while (_pages.length > capacity) {
            _pages.remove(_pages.keys.first);
          }
          notifyListeners();
        }
        // Let pdfrx render between analysis jobs; no whole-document pre-scan.
        await Future<void>.delayed(settleDelay);
      }
    } finally {
      _running = false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    invalidate();
    super.dispose();
  }
}
