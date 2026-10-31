import 'dart:async';

import 'package:podoco/podoco.dart' as podoco;

import '../previews/link_target.dart';
import '../services/pdf_session.dart';
import 'analysis_engine.dart';
import 'analysis_store.dart';
import 'pdf_analysis_source.dart';
import 'preview_layout_store.dart';

class PreviewLayoutTicket {
  PreviewLayoutTicket(this.result, this.cancel);
  final Future<AnalysisPageSnapshot?> result;
  final void Function() cancel;
}

/// Shares the manual controller's warm engine, or owns one layout-only engine.
/// Manual work preempts and drains preview inference before opening/using models.
class AnalysisCoordinator {
  AnalysisCoordinator({
    required this.store,
    required this.manualStore,
    required this.manualEngine,
    required this.openLayout,
    required this.inspectProfile,
    this.createSource = PdfAnalysisSource.create,
  });
  final PreviewLayoutStore store;
  final AnalysisStore manualStore;
  final AnalysisEngine? Function() manualEngine;
  final Future<AnalysisEngine> Function() openLayout;
  final Future<PreviewLayoutProfile> Function() inspectProfile;
  final Future<podoco.PageSource> Function(PdfSession) createSource;
  Future<PreviewLayoutProfile>? _profile;
  AnalysisEngine? _layoutEngine;
  DocumentAnalysisJob? _job;
  Future<void>? _lane, _closing;
  _PreviewPageWork? _active, _pending, _watching;
  int _manual = 0, _epoch = 0;
  bool _closed = false, _failed = false;
  bool get automaticInitializationFailed => _failed;
  bool get explicitRunning => _manual > 0;
  int get activePreviewJobs => _job == null ? 0 : 1;
  int get pendingPreviewPages => _pending == null ? 0 : 1;

  Future<PreviewLayoutProfile> _policy() => _profile ??= inspectProfile();

  void configurationReady() {
    _profile = null;
    _failed = false;
  }

  PreviewLayoutTicket request(
    LinkPreviewRequest request,
    bool Function() isCurrent,
  ) {
    final consumer = _PreviewConsumer(request, isCurrent);
    if (_closed || !consumer.current) {
      consumer.finish(null);
      return PreviewLayoutTicket(consumer.result.future, () {});
    }
    final key = (
      request.session,
      request.revision,
      request.destination.pageNumber,
    );
    var work = [_active, _pending, _watching]
        .whereType<_PreviewPageWork>()
        .where((w) => w.key == key && !w.retired)
        .firstOrNull;
    if (work == null) {
      work = _PreviewPageWork(key, cacheOnly: explicitRunning);
      _pending?.finish(null);
      _pending = work;
      if (_watching != null && _watching!.key != key) {
        _watching!.finish(null);
        _watching = null;
      }
    }
    final joined = work;
    joined.consumers.add(consumer);
    _start();
    return PreviewLayoutTicket(consumer.result.future, () {
      consumer.finish(null);
      joined.consumers.remove(consumer);
      if (joined.live.isEmpty) {
        if (identical(_active, joined)) _job?.cancel();
        if (identical(_pending, joined)) _pending = null;
        if (identical(_watching, joined)) _watching = null;
        joined.retired = true;
      }
    });
  }

  void _start() {
    if (_closed || _lane != null || _pending == null) return;
    // Set ownership before entering async work, including synchronous callbacks.
    final done = Completer<void>();
    _lane = done.future;
    unawaited(() async {
      try {
        while (!_closed && _pending != null) {
          final work = _pending!;
          _pending = null;
          _active = work;
          await _run(work);
          _active = null;
        }
      } finally {
        _lane = null;
        done.complete();
        _start();
      }
    }());
  }

  Future<void> _run(_PreviewPageWork work) async {
    final epoch = _epoch;
    bool current() =>
        !_closed && epoch == _epoch && !work.retired && work.live.isNotEmpty;
    try {
      if (!current()) return;
      final request = work.live.first.request;
      final document = analysisDocumentRef(request.session);
      final index = request.destination.pageNumber - 1;
      if (_failed) return;
      final profile = await _policy();
      if (!current()) return;
      var cached = await store.readCompatible(document, index, profile);
      if (cached == null) {
        final engine = manualEngine();
        if (engine != null) {
          cached = await manualStore.read(
            analysisCacheKey(
              document,
              engine.manifests,
              engine.profile,
              engine.computePolicy,
            ),
            index,
            document,
          );
          if (cached != null) {
            cached = await store.publish(cached, profile, current);
          }
        }
      }
      if (!current()) return;
      if (cached != null) {
        work.finish(cached);
        return;
      }
      if (explicitRunning) {
        _watching?.finish(null);
        _watching = work;
        return;
      }
      if (work.cacheOnly) {
        return; // Never enqueue a hover behind manual analysis.
      }
      final engine = manualEngine() ?? (_layoutEngine ??= await openLayout());
      if (!current() || explicitRunning) return;
      final source = await createSource(request.session);
      if (!current() ||
          explicitRunning ||
          index < 0 ||
          index >= source.pages.length) {
        return;
      }
      late DocumentAnalysisJob job;
      job = engine.analyzePage(source, index, (update) async {
        if (!current() ||
            update.analysisId != job.id ||
            update.document != document) {
          return;
        }
        if (update is! podoco.PageLayoutReady &&
            update is! podoco.PageFinished) {
          return;
        }
        final snapshot = AnalysisPageSnapshot.fromUpdate(update);
        if (snapshot.page.page.key.pageIndex != index) return;
        final saved = await store.publish(snapshot, profile, current);
        if (saved != null && current()) work.finish(saved);
      }, formulaScope: podoco.FormulaScope.none);
      _job = job;
      await job.done; // Includes native input/update/lease drain.
    } catch (_) {
      // Retry automatic initialization only after an explicit action/config change.
      // Inference/cache failures do not poison a successfully opened engine.
      if (_layoutEngine == null && manualEngine() == null) _failed = true;
    } finally {
      _job = null;
      if (!identical(_watching, work)) work.finish(null);
    }
  }

  /// Caller must release in finally. Priority is reserved synchronously, before
  /// awaiting a cooperatively cancelled preview or an in-flight model open.
  Future<void Function()> beginExplicit({
    bool configurationChanged = false,
  }) async {
    if (_closed) throw StateError('Analysis coordinator is closed');
    _manual++;
    _epoch++;
    // An explicit action retries metadata verification too, including a failed
    // projection lookup while an otherwise healthy manual engine was warm.
    _profile = null;
    _failed = false;
    if (configurationChanged) {
      _profile = null;
      _watching?.finish(null);
      _watching = null;
      _pending?.finish(null);
      _pending = null;
    } else {
      final desired = _pending ?? _active;
      if (desired != null && desired.live.isNotEmpty) {
        _watching?.finish(null);
        _watching = desired;
        desired.cacheOnly = true;
        _pending = null;
      }
    }
    _job?.cancel();
    try {
      await _lane;
      final previous = _layoutEngine;
      _layoutEngine = null;
      await previous?.close();
    } catch (_) {
      _manual--;
      _watching?.finish(null);
      _watching = null;
      rethrow;
    }
    _failed = false;
    var released = false;
    return () {
      if (released) return;
      released = true;
      _manual--;
      if (!explicitRunning) {
        _watching?.finish(null);
        _watching = null;
      }
    };
  }

  Future<void> publishManual(
    AnalysisPageSnapshot snapshot,
    bool Function() isCurrent,
  ) async {
    if (_closed || !isCurrent()) return;
    try {
      final profile = await _policy();
      final saved = await store.publish(
        snapshot,
        profile,
        () => !_closed && isCurrent(),
      );
      if (saved == null || _closed || !isCurrent()) return;
      final work = _watching;
      if (work == null) return;
      final matches = work.live.where(
        (c) =>
            analysisDocumentRef(c.request.session) ==
                snapshot.page.page.key.document &&
            c.request.destination.pageNumber ==
                snapshot.page.page.key.pageIndex + 1,
      );
      if (matches.isNotEmpty) {
        work.finish(saved);
        _watching = null;
      }
    } catch (_) {
      // Optional projection must never fail manual analysis or erase its results.
    }
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    _epoch++;
    _active?.finish(null);
    _pending?.finish(null);
    _watching?.finish(null);
    _pending = _watching = null;
    _job?.cancel();
    await _lane;
    final engine = _layoutEngine;
    _layoutEngine = null;
    await engine?.close();
  }
}

class _PreviewConsumer {
  _PreviewConsumer(this.request, this.isCurrent);
  final LinkPreviewRequest request;
  final bool Function() isCurrent;
  final result = Completer<AnalysisPageSnapshot?>();
  bool get current => !result.isCompleted && request.isCurrent && isCurrent();
  void finish(AnalysisPageSnapshot? value) {
    if (!result.isCompleted) result.complete(current ? value : null);
  }
}

class _PreviewPageWork {
  _PreviewPageWork(this.key, {required this.cacheOnly});
  final Object key;
  bool cacheOnly;
  final consumers = <_PreviewConsumer>[];
  bool retired = false;
  List<_PreviewConsumer> get live => consumers.where((c) => c.current).toList();
  void finish(AnalysisPageSnapshot? value) {
    for (final consumer in consumers) {
      consumer.finish(value);
    }
    consumers.clear();
    retired = true;
  }
}
