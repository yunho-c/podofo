import 'dart:async';

import '../services/pdf_session.dart';
import 'narration_sequence.dart';
import 'narrator.dart';
import 'paper_timeline.dart';
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
  late final PaperTimeline timeline = PaperTimeline(index);
  NarrationDurationSession? _durationSession;
  NarrationSettings? _durationSettings;
  NarrationDurationJob? _durationJob;
  Future<void>? _durationWork;

  /// Quiescence barrier used before another document admits a planning job.
  Future<void> get timingIdle => _durationWork ?? Future<void>.value();
  bool _durationRequested = false;

  void configureTiming(
    NarrationDurationSession session,
    NarrationSettings settings,
  ) {
    if (_durationSettings?.key != settings.key) {
      _durationJob?.cancel();
      timeline.configure(settings);
    }
    _durationSession = session;
    _durationSettings = settings;
    _durationRequested = true;
    _ensureTiming();
  }

  void invalidateTiming(NarrationSettings settings) {
    _durationRequested = false;
    _durationJob?.cancel();
    _durationSettings = settings;
    timeline.configure(settings);
  }

  void retryTiming() {
    timeline.retryFailures();
    _durationRequested = true;
    unawaited(indexDocument(retryFailures: true));
    _ensureTiming();
  }

  void _ensureTiming() {
    if (_closed ||
        !_durationRequested ||
        _durationSession == null ||
        _durationWork != null) {
      return;
    }
    final epoch = _epoch, settings = _durationSettings!;
    final session = _durationSession!;
    _durationRequested = false;
    late final Future<void> work;
    work = Future<void>(() => _timeDocument(epoch, session, settings))
        .whenComplete(() {
          if (identical(_durationWork, work)) _durationWork = null;
          _ensureTiming();
        });
    _durationWork = work;
  }

  Future<void> _timeDocument(
    int epoch,
    NarrationDurationSession session,
    NarrationSettings settings,
  ) async {
    bool valid() =>
        !_closed && epoch == _epoch && settings.key == _durationSettings?.key;
    if (!valid()) return;
    timeline.setPlanning(true);
    try {
      await indexDocument();
      if (!valid()) return;
      for (final page in index.snapshot.pages) {
        if (!valid()) return;
        if (page.page > index.scopeEndPage) break;
        if (page.unresolved ||
            page.status == PaperIndexPageStatus.skipped ||
            page.passages.every(
              (p) =>
                  timeline.timing(p.id) != null ||
                  timeline.failure(p.id) != null,
            )) {
          continue;
        }
        final PaperPagePlan plan;
        try {
          plan =
              _pages[page.page] ??
              await planner.plan(
                page.page,
                options,
                priority: PaperPlanPriority.background,
              );
        } on PaperPlanningCancelled {
          return;
        } catch (error) {
          if (valid()) {
            for (final passage in page.passages) {
              timeline.fail(passage.id, error);
            }
          }
          continue;
        }
        if (!valid()) return;
        index.record(plan, options);
        if (plan.issue != null) continue;
        final descriptors = index.page(page.page)!.passages;
        for (var i = 0; i < descriptors.length; i++) {
          if (!valid()) return;
          final descriptor = descriptors[i];
          if (timeline.timing(descriptor.id) != null ||
              timeline.failure(descriptor.id) != null) {
            continue;
          }
          NarrationDurationJob? job;
          try {
            job = session.planDuration(plan.passages[i].text, settings);
            _durationJob = job;
            final result = await job.result;
            if (!valid()) return;
            if (result != null) timeline.record(descriptor, result);
          } catch (error) {
            if (valid()) timeline.fail(descriptor.id, error);
          } finally {
            // Disposal closes the public handle before its asynchronous join.
            // Stop/settings/seek may run during that join; only live jobs may
            // remain reachable through the cancellation slot.
            if (identical(_durationJob, job)) _durationJob = null;
            await job?.dispose();
          }
          await Future<void>.delayed(Duration.zero);
        }
      }
    } finally {
      if (!_closed) timeline.setPlanning(false);
    }
  }

  NarrationPassage _passageAt(PaperPagePlan plan, int ordinal) {
    final passage = plan.passages[ordinal];
    return NarrationPassage(
      passage.text,
      passage.spans,
      indexedPassageId: index.page(plan.page.page)!.passages[ordinal].id,
    );
  }

  PaperReadOptions _options;
  PaperReadOptions get options => _options;
  set options(PaperReadOptions value) {
    if (value.key == _options.key) return;
    final restart = _indexStarted;
    cancelPending();
    _options = value;
    _pages.clear();
    _skipped.clear();
    review = null;
    index.reset();
    if (restart) {
      unawaited(indexDocument());
      _durationRequested = _durationSession != null;
      _ensureTiming();
    }
  }

  final _pages = <int, PaperPagePlan>{};
  final _skipped = <int>{};
  int _page = 1, _passage = -1, _epoch = 0, _movement = 0;
  bool _closed = false, _indexStarted = false;
  Future<void>? _indexing;
  PaperPagePlan? review;
  int get cachedPageCount => _pages.length;

  /// Geometry already retained for playback; never extracts or promotes a page.
  NarrationPassage? cachedSeekPassage(PaperSeekTarget target) {
    if (!timeline.accepts(target)) return null;
    final plan = _pages[target.passage.page];
    if (plan == null ||
        plan.page.textHash != target.passage.anchor.textHash ||
        target.passage.ordinal >= plan.passages.length) {
      return null;
    }
    return plan.passages[target.passage.ordinal];
  }

  int get pageNumber => _page;
  int get pageCount => planner.pageCount;

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
    final preferences = options;
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
      final preferences = options;
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

  /// Prepare a destination without moving the playback cursor or opening review.
  Future<ResolvedPaperSeek> resolveSeek(PaperSeekTarget target) async {
    final epoch = _epoch;
    if (_closed || !timeline.accepts(target)) {
      throw StateError('Document timing changed. Try again.');
    }
    final page = target.passage.page;
    // Re-extract even if cached: validate the frozen text identity at admission.
    final plan = await planner.plan(
      page,
      options,
      priority: PaperPlanPriority.playback,
    );
    if (_closed || epoch != _epoch || !timeline.accepts(target)) {
      throw PaperPlanningCancelled();
    }
    index.record(plan, options);
    if (plan.issue != null) throw PaperReviewRequired(plan);
    if (!timeline.accepts(target)) {
      throw StateError('This passage changed. Review the page before seeking.');
    }
    final ordinal = target.passage.ordinal;
    return ResolvedPaperSeek(
      _passageAt(plan, ordinal),
      plan,
      ordinal,
      epoch,
      target,
    );
  }

  void commitSeek(ResolvedPaperSeek destination) {
    if (_closed ||
        destination.epoch != _epoch ||
        !timeline.accepts(destination.target)) {
      throw PaperPlanningCancelled();
    }
    _page = destination.plan.page.page;
    _passage = destination.ordinal;
    review = null;
    _pages.remove(_page);
    _pages[_page] = destination.plan;
    while (_pages.length > 2) {
      _pages.remove(_pages.keys.first);
    }
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
          return _passageAt(plan, i).sliceFrom(passage.offsetOf(anchor)!);
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
        return _passageAt(plan, passage);
      }
      if (direction > 0 && plan.endsPaper) return null;
      page += direction;
      passage = direction > 0 ? 0 : -1;
    }
    return null;
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
    if (restart) {
      unawaited(indexDocument());
      _durationRequested = _durationSession != null;
      _ensureTiming();
    }
  }

  @override
  void cancelPending() {
    _durationRequested = false;
    _durationJob?.cancel();
    timeline.setPlanning(false);
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
    _skipped.clear();
    review = null;
    planner.close();
    timeline.dispose();
    index.close();
  }
}

class ResolvedPaperSeek {
  const ResolvedPaperSeek(
    this.passage,
    this.plan,
    this.ordinal,
    this.epoch,
    this.target,
  );
  final NarrationPassage passage;
  final PaperPagePlan plan;
  final int ordinal, epoch;
  final PaperSeekTarget target;
}
