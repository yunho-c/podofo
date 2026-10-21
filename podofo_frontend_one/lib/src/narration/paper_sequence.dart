import 'dart:async';

import '../services/pdf_session.dart';
import 'narration_sequence.dart';
import 'paper_index.dart';
import 'paper_page_planner.dart';
import 'paper_plan.dart';
import 'pdf_text_repository.dart';
import 'source_map.dart';

class PaperReviewRequired implements Exception {
  PaperReviewRequired(this.plan);
  final PaperPagePlan plan;
  @override
  String toString() =>
      plan.issue ?? 'Review page ${plan.page.page} before continuing.';
}

/// Two playback page plans plus a compact, independent document text index.
class PaperSequence implements NarrationSequence, DocumentIndexingSequence {
  PaperSequence(PdfSession session, PaperReadOptions options)
    : this.withPlanner(
        PaperPagePlanner(
          pageCount: session.lease.document.pages.length,
          extract: PdfTextRepository(session).extract,
        ),
        options,
      );

  /// Owns the shared planner; injectable for extraction scheduling tests.
  PaperSequence.withPlanner(this.planner, this._options)
    : index = PaperIndex(planner.pageCount);
  final PaperPagePlanner planner;
  final PaperIndex index;
  PaperReadOptions _options;
  PaperReadOptions get options => _options;
  set options(PaperReadOptions value) {
    if (value.key == _options.key) return;
    final restart = _indexStarted;
    cancelPending();
    _options = value;
    _pages.clear();
    _overrides.clear();
    _skipped.clear();
    review = null;
    index.reset();
    if (restart) unawaited(indexDocument());
  }

  final _pages = <int, PaperPagePlan>{};
  final _overrides = <int, PaperOrder>{};
  final _skipped = <int>{};
  int _page = 1, _passage = -1, _epoch = 0, _movement = 0;
  bool _closed = false, _indexStarted = false;
  Future<void>? _indexing;
  PaperPagePlan? review;
  int get cachedPageCount => _pages.length;
  int get pageNumber => _page;
  int get pageCount => planner.pageCount;

  PaperReadOptions _preferences(int page) {
    final order = _overrides[page];
    return order == null
        ? options
        : PaperReadOptions(
            order: order,
            stopAtReferences: options.stopAtReferences,
            skipCaptions: options.skipCaptions,
            skipRunningMatter: options.skipRunningMatter,
          );
  }

  /// Preview has no index/cursor side effects and never starts a document scan.
  Future<PaperPagePlan> preview(int number, {PaperReadOptions? preferences}) =>
      planner.plan(number, preferences ?? options);

  Future<PaperPagePlan> _plan(
    int page,
    int epoch, {
    PaperPlanPriority priority = PaperPlanPriority.playback,
  }) async {
    if (_closed || epoch != _epoch) throw PaperPlanningCancelled();
    final cached = _pages.remove(page);
    if (cached != null) {
      _pages[page] = cached;
      return cached;
    }
    final preferences = _preferences(page);
    final plan = await planner.plan(page, preferences, priority: priority);
    if (_closed || epoch != _epoch) throw PaperPlanningCancelled();
    _pages[page] = plan;
    while (_pages.length > 2) {
      _pages.remove(_pages.keys.first);
    }
    index.record(plan, preferences);
    return plan;
  }

  @override
  Future<void> prepareNext() async {
    if (_closed || _page >= pageCount || _pages[_page]?.endsPaper == true) {
      return;
    }
    await _plan(_page + 1, _epoch, priority: PaperPlanPriority.prefetch);
  }

  @override
  Future<void> indexDocument({bool retryFailures = false}) {
    if (_closed) return Future.value();
    _indexStarted = true;
    if (_indexing != null) return _indexing!;
    if (!retryFailures &&
        index.snapshot.status == PaperIndexStatus.scanned &&
        index.snapshot.scanFinished) {
      return Future.value();
    }
    final epoch = _epoch;
    // Deferring admission allows callers to publish the future before listeners
    // react to progress, and gives foreground preparation first admission.
    late final Future<void> work;
    work = Future<void>(() => _scan(epoch)).whenComplete(() {
      if (identical(_indexing, work)) _indexing = null;
    });
    _indexing = work;
    return work;
  }

  Future<void> _scan(int epoch) async {
    if (_closed || epoch != _epoch) return;
    index.begin();
    for (var page = 1; page <= index.scopeEndPage; page++) {
      if (_closed || epoch != _epoch) return;
      if (_skipped.contains(page)) {
        if (index.page(page)?.status != PaperIndexPageStatus.skipped) {
          index.skip(page);
        }
        continue;
      }
      if (index.page(page) != null) continue;
      final preferences = _preferences(page);
      try {
        // Matching playback/prefetch work is shared by the planner. Background
        // results never enter or evict the two-page detailed playback cache.
        final plan = await planner.plan(
          page,
          preferences,
          priority: PaperPlanPriority.background,
        );
        if (_closed || epoch != _epoch) return;
        if (!_skipped.contains(page)) index.record(plan, preferences);
      } on PaperPlanningCancelled {
        return;
      } catch (error) {
        if (_closed || epoch != _epoch) return;
        index.fail(page, error);
      }
      await Future<void>.delayed(Duration.zero);
    }
    if (!_closed && epoch == _epoch) index.finish();
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
    final restart = _indexStarted;
    cancelPending();
    _overrides[page] = order;
    _pages.remove(page);
    index.invalidate(page);
    review = null;
    if (restart) unawaited(indexDocument());
  }

  void skipReview() {
    final page = review?.page.page;
    if (page == null) return;
    final restart = _indexStarted;
    cancelPending();
    _skipped.add(page);
    _pages.remove(page);
    index.skip(page);
    review = null;
    if (restart) unawaited(indexDocument());
  }

  @override
  void cancelPending() {
    _epoch++;
    _indexStarted = false;
    _indexing = null;
    planner.cancelPending();
    index.cancel();
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    cancelPending();
    _pages.clear();
    _overrides.clear();
    _skipped.clear();
    review = null;
    planner.close();
    index.close();
  }
}
