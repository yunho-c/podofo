import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:podoco/podoco.dart' as podoco;

import '../services/pdf_session.dart';
import 'analysis_store.dart';
import 'preview_layout_repository.dart';
import 'analysis_engine.dart';
import 'pdf_analysis_source.dart';

/// One analysis lane shared by reader tabs, with only the visible page retained.
/// Rust bounds pipeline inputs/results; the app bounds persisted derived pages.
class AnalysisController extends ChangeNotifier {
  AnalysisController({
    required this.store,
    this.open = NativeAnalysisEngine.open,
    this.openBundled,
  });
  final AnalysisStore store;
  final Future<AnalysisEngine> Function(AnalysisModelPaths) open;
  final Future<AnalysisEngine> Function(void Function(String))? openBundled;
  AnalysisModelPaths? modelPaths;
  AnalysisEngine? _engine;
  DocumentAnalysisJob? _job;
  Future<void>? _operation;
  Future<void>? _configuration;
  Future<void>? _closing;
  PdfSession? _session;
  podoco.DocumentRef? _document;
  int _generation = 0, _viewGeneration = 0, _pageIndex = 0;
  bool _disposed = false;
  bool showRegions = true;
  AnalysisPageSnapshot? visibleSnapshot;
  podoco.AnalysisProgress? progress;
  podoco.AnalysisOutcome? outcome;
  String? error;
  String? preparation;
  bool get hasBundledModels => openBundled != null;
  bool get usingBundledModels => modelPaths == null && hasBundledModels;
  bool get canAnalyze =>
      _session != null && (ready || modelPaths != null || hasBundledModels);
  bool get ready => _engine != null;
  bool get recognizesFormulas => _engine?.recognizesFormulas ?? false;
  bool get opening => _configuration != null;
  bool get running => _operation != null;
  podoco.PageAnalysis? get visiblePage => visibleSnapshot?.page;
  bool get pageComplete => visibleSnapshot?.complete ?? false;
  PdfSession? get session => _session;
  String? get _key => _document == null || _engine == null
      ? null
      : analysisCacheKey(
          _document!,
          _engine!.manifests,
          _engine!.profile,
          _engine!.computePolicy,
        );

  PreviewAnalysisIdentity? get previewIdentity =>
      _disposed || _document == null || _engine == null
      ? null
      : PreviewAnalysisIdentity(
          _document!,
          _engine!.manifests,
          _engine!.profile,
          _engine!.computePolicy,
        );

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  bool _current(
    int generation,
    PdfSession session,
    podoco.DocumentRef document,
  ) =>
      !_disposed &&
      generation == _generation &&
      identical(session, _session) &&
      !session.lease.isClosed &&
      analysisDocumentRef(session) == document;

  void select(PdfSession? session, int pageIndex) {
    if (_disposed) return;
    final document = session == null || session.lease.isClosed
        ? null
        : analysisDocumentRef(session);
    final changed = !identical(session, _session) || document != _document;
    if (changed) {
      _generation++;
      _job?.cancel();
      _session = session;
      _document = document;
      outcome = null;
      progress = null;
      error = null;
    }
    if (changed || _pageIndex != pageIndex) {
      _pageIndex = pageIndex;
      visibleSnapshot = null;
      unawaited(_restore());
      _notify();
    }
  }

  Future<void> _restore() async {
    final view = ++_viewGeneration, generation = _generation;
    final key = _key,
        session = _session,
        document = _document,
        index = _pageIndex;
    if (key == null || session == null || document == null) return;
    final cached = await store.read(key, index, document);
    if (view == _viewGeneration && _current(generation, session, document)) {
      visibleSnapshot = cached;
      _notify();
    }
  }

  Future<void> configure(String directory, {String? formulaDirectory}) {
    if (_disposed) throw StateError('Analysis controller is closed');
    if (_configuration != null) return _configuration!;
    final paths = AnalysisModelPaths(directory, formula: formulaDirectory);
    modelPaths = paths;
    final task = _configure(() => open(paths));
    _configuration = task;
    _notify();
    return task;
  }

  Future<void> useBundledModels() {
    if (_disposed || !hasBundledModels) {
      throw StateError('Bundled analysis is unavailable');
    }
    if (_configuration != null) return _configuration!;
    modelPaths = null;
    final task = _configure(() async => null);
    _configuration = task;
    _notify();
    return task;
  }

  void _preparing(String value) {
    if (!_disposed) {
      preparation = value;
      _notify();
    }
  }

  Future<void> _configure(
    Future<AnalysisEngine?> Function() create, {
    bool retireAnalysis = true,
  }) async {
    if (retireAnalysis) {
      _generation++;
      _job?.cancel();
    }
    error = null;
    visibleSnapshot = null;
    try {
      if (retireAnalysis) await _operation;
      final previous = _engine;
      _engine = null;
      await previous?.close();
      final candidate = await create();
      if (_disposed) {
        await candidate?.close();
        return;
      }
      _engine = candidate;
      await _restore();
    } catch (e) {
      if (!_disposed) error = e.toString();
    } finally {
      _configuration = null;
      preparation = null;
      _notify();
    }
  }

  Future<void> analyze() {
    if (_operation != null) return _operation!;
    if (_disposed ||
        !canAnalyze ||
        opening ||
        _session == null ||
        _document == null) {
      throw StateError('Select a PDF and an available analysis source first');
    }
    final task = _prepareAndAnalyze();
    _operation = task;
    _notify();
    return task;
  }

  Future<void> _prepareAndAnalyze() async {
    final session = _session!, document = _document!, generation = _generation;
    try {
      if (_engine == null) {
        final paths = modelPaths;
        final task = _configure(
          () => paths != null ? open(paths) : openBundled!(_preparing),
          retireAnalysis: false,
        );
        _configuration = task;
        _notify();
        await task;
      }
      if (_engine == null || !_current(generation, session, document)) return;
      await _analyze();
    } finally {
      _operation = null;
      _notify();
    }
  }

  Future<void> _analyze() async {
    final session = _session!, document = _document!, engine = _engine!;
    final generation = ++_generation;
    final key = _key!;
    error = null;
    outcome = null;
    progress = null;
    StreamSubscription<podoco.AnalysisProgress>? subscription;
    DocumentAnalysisJob? job;
    try {
      final source = await PdfAnalysisSource.create(session);
      if (!_current(generation, session, document)) return;
      job = engine.analyze(source, (update) async {
        bool current() =>
            _current(generation, session, document) &&
            update.document == document &&
            update.analysisId == job!.id;
        if (!current()) return;
        final saved = await store.apply(key, update, current);
        if (saved != null &&
            current() &&
            saved.page.page.key.pageIndex == _pageIndex) {
          ++_viewGeneration; // A pending old disk read must not replace this update.
          visibleSnapshot = saved;
          _notify();
        }
      });
      _job = job;
      subscription = job.progress.listen((value) {
        if (!_current(generation, session, document)) {
          job?.cancel();
          return;
        }
        progress = value;
        _notify();
      });
      final result = await job.done;
      if (_current(generation, session, document)) {
        outcome = result;
        progress = result.progress;
        error = result.error?.toString();
      }
    } catch (e) {
      if (_current(generation, session, document)) error = e.toString();
    } finally {
      await subscription?.cancel();
      if (identical(_job, job)) _job = null;
      _notify();
    }
  }

  void cancel() {
    if (_job == null && running) ++_generation;
    _job?.cancel();
  }

  void toggleRegions(bool value) {
    showRegions = value;
    _notify();
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _disposed = true;
    ++_generation;
    ++_viewGeneration;
    _job?.cancel();
    await _operation;
    await _configuration;
    final engine = _engine;
    _engine = null;
    await engine?.close();
  }

  @override
  void dispose() {
    close().ignore();
    super.dispose();
  }
}
