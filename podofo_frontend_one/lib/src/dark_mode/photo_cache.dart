import 'dart:async';

import 'package:flutter/foundation.dart';

import 'photo_analysis.dart';

typedef PhotoLoader = Future<PhotoPageAnalysis> Function(
  int page,
  PhotoPageAnalysis? previous,
  List<String> priority,
);

/// One session/revision, bounded LRU and one native batch at a time. Completed
/// decisions are cached; pending images resume fairly across visible pages.
class PhotoAnalysisCache extends ChangeNotifier {
  PhotoAnalysisCache(
    this.load, {
    this.capacity = 64,
    this.settleDelay = const Duration(milliseconds: 150),
    this.batchDelay = const Duration(milliseconds: 32),
  });
  final PhotoLoader load;
  final int capacity;
  final Duration settleDelay, batchDelay;
  Map<int, List<String>> _priorities = const {};
  int? _lastPage;
  final _pages = <int, PhotoPageAnalysis>{};
  List<int> _visible = const [];
  Timer? _timer, _batchTimer;
  Completer<void>? _batchWait;
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

  void setVisiblePages(
    List<int> pages, {
    Map<int, List<String>> priorities = const {},
  }) {
    if (_disposed) return;
    _priorities = priorities;
    // At extreme zoom-out, keep a bounded working set without LRU thrashing.
    final bounded = pages.take(capacity).toList(growable: false);
    if (_disposed || listEquals(_visible, bounded)) return;
    _visible = bounded;
    _timer?.cancel();
    if (_visible.isEmpty) _cancelBatchWait();
    if (_visible.isNotEmpty) _timer = Timer(settleDelay, _drain);
  }

  void invalidate() {
    _epoch++;
    _pages.clear();
    _priorities = const {};
    _lastPage = null;
    _visible = const [];
    _timer?.cancel();
    _cancelBatchWait();
    // A read in flight owns its lease until completion; its result is discarded.
  }

  Future<void> _drain() async {
    if (_disposed || _running) return;
    _running = true;
    try {
      while (!_disposed) {
        final pending = _visible
            .where((p) => !(_pages[p]?.isComplete ?? false))
            .toList();
        if (pending.isEmpty) break;
        final lastIndex = _visible.indexOf(_lastPage ?? -1);
        final page = pending.firstWhere(
          (p) => _visible.indexOf(p) > lastIndex,
          orElse: () => pending.first,
        );
        _lastPage = page;
        final previous = _pages[page];
        final epoch = _epoch;
        final watch = Stopwatch()..start();
        PhotoPageAnalysis result;
        try {
          analyses++;
          result = await load(page, previous, _priorities[page] ?? const []);
          if (previous != null &&
              !result.isComplete &&
              result.pendingCount >= previous.pendingCount) {
            result = PhotoPageAnalysis.failed(previous, 'analysis-stalled');
          }
        } catch (_) {
          result = PhotoPageAnalysis.failed(previous, 'analysis-unavailable');
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
        if (_disposed ||
            !_visible.any((p) => !(_pages[p]?.isComplete ?? false))) {
          break;
        }
        await _yieldToRenderer();
      }
    } finally {
      _running = false;
    }
  }

  Future<void> _yieldToRenderer() {
    final wait = Completer<void>();
    _batchWait = wait;
    _batchTimer = Timer(batchDelay, () {
      _batchTimer = null;
      _batchWait = null;
      wait.complete();
    });
    return wait.future;
  }

  void _cancelBatchWait() {
    _batchTimer?.cancel();
    _batchTimer = null;
    _batchWait?.complete();
    _batchWait = null;
  }

  @override
  void dispose() {
    _disposed = true;
    invalidate();
    super.dispose();
  }
}
