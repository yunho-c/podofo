import 'dart:async';

import 'paper_plan.dart';
import 'pdf_text_repository.dart';
import 'running_matter.dart';

/// Order of admission to the shared PDF extraction lane.
enum PaperPlanPriority { playback, prefetch, background }

class PaperPlanningCancelled extends StateError {
  PaperPlanningCancelled() : super('Reading was cancelled.');
}

class _YieldPlan implements Exception {}

class _PlanWork {
  _PlanWork(this.page, this.options, this.priority, this.epoch);
  final int page, epoch;
  final PaperReadOptions options;
  PaperPlanPriority priority;
  final result = Completer<PaperPagePlan>();
}

/// One detached target plus one neighboring snapshot per active plan. Matching
/// callers share work; a foreground caller can promote an in-flight index job.
/// A lower-priority plan yields by dropping its snapshots and retrying later.
class PaperPagePlanner {
  PaperPagePlanner({required this.pageCount, required this.extract});
  final int pageCount;
  final Future<ExtractedPaperPage> Function(int page) extract;
  final _queue = <_PlanWork>[];
  final _pending = <(int, String), _PlanWork>{};
  int _epoch = 0;
  bool _running = false, _closed = false;
  int extractionCount = 0, activeExtractions = 0, peakExtractions = 0;
  int yieldedPlans = 0;

  Future<PaperPagePlan> plan(
    int page,
    PaperReadOptions options, {
    PaperPlanPriority priority = PaperPlanPriority.playback,
  }) {
    if (_closed) return Future.error(PaperPlanningCancelled());
    if (page < 1 || page > pageCount) {
      return Future.error(RangeError.range(page, 1, pageCount, 'page'));
    }
    final key = (page, options.key);
    final existing = _pending[key];
    if (existing != null) {
      if (priority.index < existing.priority.index) {
        existing.priority = priority;
      }
      return existing.result.future;
    }
    final work = _PlanWork(page, options, priority, _epoch);
    _pending[key] = work;
    _queue.add(work);
    if (!_running) unawaited(_drain());
    return work.result.future;
  }

  void _check(_PlanWork work) {
    if (_closed || work.epoch != _epoch) throw PaperPlanningCancelled();
    if (_queue.any((other) => other.priority.index < work.priority.index)) {
      throw _YieldPlan();
    }
  }

  Future<ExtractedPaperPage> _extract(int page, _PlanWork work) async {
    _check(work);
    extractionCount++;
    activeExtractions++;
    if (activeExtractions > peakExtractions) {
      peakExtractions = activeExtractions;
    }
    try {
      final result = await extract(page);
      _check(work);
      return result;
    } finally {
      activeExtractions--;
    }
  }

  Future<PaperPagePlan> _prepare(_PlanWork work) async {
    final page = await _extract(work.page, work);
    final candidates = work.options.skipRunningMatter
        ? marginLines(page)
        : <MarginLine>[];
    final confirmed = <MarginLine>{};
    if (candidates.isNotEmpty) {
      for (final other in [
        work.page - 1,
        work.page + 1,
        work.page - 2,
        work.page + 2,
      ]) {
        if (other < 1 || other > pageCount) continue;
        // No native objects survive extract(); only this neighbor's signatures
        // survive the next await, never its text or glyph rectangles.
        final lines = marginLines(await _extract(other, work));
        confirmed.addAll(
          candidates.where((candidate) => lines.any(candidate.matches)),
        );
        if (confirmed.length == candidates.length) break;
        await Future<void>.delayed(Duration.zero);
      }
    }
    _check(work);
    return PaperPlanner.plan(
      page.text,
      work.options,
      runningMatter: confirmed.toList(),
    );
  }

  Future<void> _drain() async {
    _running = true;
    try {
      while (_queue.isNotEmpty) {
        // Stable admission order within each priority.
        var best = 0;
        for (var i = 1; i < _queue.length; i++) {
          if (_queue[i].priority.index < _queue[best].priority.index) best = i;
        }
        final work = _queue.removeAt(best);
        var retry = false;
        try {
          final plan = await _prepare(work);
          _check(work);
          work.result.complete(plan);
        } on _YieldPlan {
          retry = true;
          yieldedPlans++;
          _queue.add(work);
        } catch (error, stack) {
          work.result.completeError(error, stack);
        } finally {
          final key = (work.page, work.options.key);
          if (!retry && identical(_pending[key], work)) _pending.remove(key);
        }
        // Let playback, Stop and document close run between background pages.
        await Future<void>.delayed(Duration.zero);
      }
    } finally {
      _running = false;
    }
  }

  void cancelPending() {
    _epoch++;
    for (final work in _queue) {
      work.result.completeError(PaperPlanningCancelled());
    }
    _queue.clear();
    _pending.clear();
  }

  void close() {
    if (_closed) return;
    _closed = true;
    cancelPending();
  }
}
