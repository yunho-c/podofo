import '../services/pdf_session.dart';
import 'narration_sequence.dart';
import 'paper_plan.dart';
import 'pdf_text_repository.dart';
import 'running_matter.dart';
import 'source_map.dart';

class PaperReviewRequired implements Exception {
  PaperReviewRequired(this.plan);
  final PaperPagePlan plan;
  @override
  String toString() =>
      plan.issue ?? 'Review page ${plan.page.page} before continuing.';
}

/// Two cached pages; no document-wide audio queue or full-paper extraction.
class PaperSequence implements NarrationSequence {
  PaperSequence(this.session, this.options);
  final PdfSession session;
  PaperReadOptions options;
  final _pages = <int, PaperPagePlan>{};
  final _pending = <int, Future<PaperPagePlan>>{};
  final _overrides = <int, PaperOrder>{};
  final _skipped = <int>{};
  int _page = 1, _passage = -1, _epoch = 0, _movement = 0;
  bool _closed = false;
  PaperPagePlan? review;
  int get cachedPageCount => _pages.length;
  int get pageNumber => _page;
  int get pageCount => session.lease.document.pages.length;

  Future<PaperPagePlan> preview(
    int number, {
    PaperReadOptions? preferences,
  }) async {
    final selected = preferences ?? options;
    final epoch = _epoch;
    void check() {
      if (_closed || epoch != _epoch) {
        throw StateError('Reading was cancelled.');
      }
    }

    check();
    final repository = PdfTextRepository(session);
    final page = await repository.extract(number);
    check();
    // Detached text/layout analysis runs after the session's native lock exits.
    final candidates = selected.skipRunningMatter
        ? marginLines(page)
        : <MarginLine>[];
    final confirmed = <MarginLine>{};
    if (candidates.isNotEmpty) {
      // One neighboring snapshot at a time, including alternating odd/even
      // running titles. No whole-paper extraction or unbounded snapshot cache.
      for (final other in [number - 1, number + 1, number - 2, number + 2]) {
        if (other < 1 || other > pageCount) continue;
        final neighbor = await repository.extract(other);
        check();
        final lines = marginLines(neighbor);
        confirmed.addAll(
          candidates.where((candidate) => lines.any(candidate.matches)),
        );
        if (confirmed.length == candidates.length) break;
      }
    }
    return PaperPlanner.plan(
      page.text,
      page.width,
      selected,
      runningMatter: confirmed.toList(),
    );
  }

  Future<PaperPagePlan> _plan(int page, int epoch) {
    if (_closed || epoch != _epoch) {
      return Future.error(StateError('Reading was cancelled.'));
    }
    final cached = _pages.remove(page);
    if (cached != null) {
      _pages[page] = cached;
      return Future.value(cached);
    }
    return _pending[page] ??= _loadPlan(page, epoch);
  }

  Future<PaperPagePlan> _loadPlan(int page, int epoch) async {
    try {
      final override = _overrides[page];
      final plan = await preview(
        page,
        preferences: override == null
            ? options
            : PaperReadOptions(
                order: override,
                stopAtReferences: options.stopAtReferences,
                skipCaptions: options.skipCaptions,
                skipRunningMatter: options.skipRunningMatter,
              ),
      );
      if (_closed || epoch != _epoch) {
        throw StateError('Reading was cancelled.');
      }
      _pages[page] = plan;
      while (_pages.length > 2) {
        _pages.remove(_pages.keys.first);
      }
      return plan;
    } finally {
      if (epoch == _epoch) _pending.remove(page);
    }
  }

  @override
  Future<void> prepareNext() async {
    if (_closed || _page >= pageCount || _pages[_page]?.endsPaper == true) {
      return;
    }
    await _plan(_page + 1, _epoch);
  }

  Future<NarrationPassage?> start({int page = 1, SourceAnchor? anchor}) async {
    if (page < 1 || page > pageCount) {
      throw StateError('The saved page is no longer in this paper.');
    }
    _page = page;
    _passage = -1;
    final epoch = _epoch;
    final plan = await _plan(page, epoch);
    if (plan.issue != null) {
      review = plan;
      throw PaperReviewRequired(plan);
    }
    if (anchor != null) {
      if (anchor.textHash != plan.page.textHash ||
          anchor.page != page ||
          anchor.offset < 0 ||
          anchor.offset >= plan.page.text.length) {
        throw StateError(
          'This paper changed since your last reading. Start again from this page.',
        );
      }
      for (var i = 0; i < plan.passages.length; i++) {
        final passage = plan.passages[i];
        final contains = passage.spans.any(
          (s) =>
              s.source.offset <= anchor.offset && s.sourceEnd > anchor.offset,
        );
        if (contains) {
          _passage = i;
          return passage.sliceFrom(passage.offsetOf(anchor)!);
        }
      }
      throw StateError(
        'The saved position is excluded by these reading options. Start again from this page.',
      );
    }
    return move(1);
  }

  @override
  Future<NarrationPassage?> move(int direction) async {
    if (_closed) throw StateError('This paper was closed.');
    final epoch = _epoch, movement = ++_movement;
    var page = _page, passage = _passage + direction;
    while (page >= 1 && page <= pageCount) {
      if (_skipped.contains(page)) {
        page += direction;
        passage = direction > 0 ? 0 : -1;
        continue;
      }
      final plan = await _plan(page, epoch);
      if (_closed || epoch != _epoch || movement != _movement) {
        throw StateError('Reading was cancelled.');
      }
      if (plan.issue != null) {
        review = plan;
        throw PaperReviewRequired(plan);
      }
      if (direction < 0 && passage == -1 && page != _page) {
        passage = plan.passages.length - 1;
      }
      if (passage >= 0 && passage < plan.passages.length) {
        _page = page;
        _passage = passage;
        review = null;
        return plan.passages[passage];
      }
      if (direction > 0 && plan.endsPaper) return null;
      page += direction;
      passage = direction > 0 ? 0 : -1;
    }
    return null;
  }

  void acceptReview(PaperOrder order) {
    final page = review?.page.page;
    if (page == null) return;
    _overrides[page] = order;
    _pages.remove(page);
    review = null;
  }

  void skipReview() {
    final page = review?.page.page;
    if (page != null) _skipped.add(page);
    review = null;
  }

  @override
  void cancelPending() {
    _epoch++;
    _pending.clear();
  }

  @override
  void close() {
    _closed = true;
    cancelPending();
    _pages.clear();
  }
}
