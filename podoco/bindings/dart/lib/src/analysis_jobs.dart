part of 'analysis.dart';

final Object _callbackOwner = Object();
void _canWait(Analyzer analyzer) {
  if (identical(Zone.current[_callbackOwner], analyzer)) {
    throw StateError(
      'Source/sink callbacks cannot await completion or disposal of their analyzer jobs; cancel is safe.',
    );
  }
}

/// Cooperative renderer control. A native failure also requests cancellation.
class CancellationToken {
  final _cancelled = Completer<void>();
  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get cancelled => _cancelled.future;
  void _cancel() {
    if (!isCancelled) _cancelled.complete();
  }
}

class RasterRequirements {
  final PixelFormat preferredFormat;
  final List<int> backgroundRgb;
  RasterRequirements._(JsonObject j)
    : preferredFormat = _enum(PixelFormat.values, j['preferred_format']),
      backgroundRgb = List.unmodifiable(_list(j['background_rgb']).map(_uint));
}

class PageRequest {
  final PageDescriptor page;
  final RasterRequirements requirements;
  final int byteBudget;
  final CancellationToken cancellation;
  PageRequest._(JsonObject j, this.cancellation)
    : page = PageDescriptor.fromJson(_map(j['page'])),
      requirements = RasterRequirements._(_map(j['requirements'])),
      byteBudget = _uint(j['byte_budget']);
}

/// Immutable cheap metadata plus a lazy renderer. Returned images transfer to
/// the job, including late renders after cancellation; the pump releases them.
abstract interface class PageSource {
  DocumentRef get document;
  List<PageDescriptor> get pages;
  Future<PageInput> loadPage(PageRequest request);
}

/// One persistent native inference lane. Opening/disposal run off the UI isolate.
class Analyzer {
  int _handle;
  final AnalyzerOptions options;
  final Capabilities capabilities;
  final String profile;

  /// Authoritative verified manifest hashes, in pipeline order. Include these,
  /// [profile] and compute policy in derived-result cache identities.
  final List<String> modelManifests;
  final Set<AnalysisJob> _jobs = {};
  Future<void>? _closing;
  Analyzer._(
    this._handle,
    this.options,
    JsonObject info,
    String fallbackManifest,
  ) : capabilities = Capabilities._(_map(info['capabilities'])),
      modelManifests = List.unmodifiable(
        _list(info['model_manifests'] ?? [fallbackManifest]).map(_sha),
      ),
      profile = _text(info['profile']) {
    _handleFinalizer.attach(this, _handle, detach: this);
  }
  static Future<Analyzer> open(
    ModelBundle bundle, {
    required AnalyzerOptions options,
    FormulaBundle? formulaBundle,
    FormulaOptions? formulaOptions,
  }) async {
    if (formulaOptions != null && formulaBundle == null) {
      throw ArgumentError('formulaOptions requires a formulaBundle');
    }
    if (formulaBundle != null) _requireFormulaExtension();
    final config = {
      'schema_version': 0,
      'bundle_directory': bundle.directory,
      'options': options.toJson(),
      if (formulaBundle != null)
        'formula_bundle_directory': formulaBundle.directory,
      if (formulaOptions != null)
        'formula_options': formulaOptions.maxNewTokens,
    };
    final handle = await Isolate.run(() => _openNative(config));
    try {
      final info = _takeJson(
        _newHandle(
          (out, error) => native.podoco_analyzer_info(handle, out, error),
        ),
      );
      _schema(info);
      if (formulaBundle != null &&
          (_list(info['model_manifests']).length != 2 ||
              _map(info['capabilities'])['formula_recognition'] != true)) {
        throw const FormatException(
          'Native analyzer did not enable the requested formula pipeline',
        );
      }
      return Analyzer._(handle, options, info, bundle.manifestSha256);
    } catch (_) {
      await _releaseAsync(handle);
      rethrow;
    }
  }

  /// Eager submission with a required serial async sink. Await job.done even if
  /// progress is never observed. Unsupported formula work fails before rendering.
  AnalysisJob analyzeDocument({
    required PageSource pages,
    required AnalysisOptions options,
    required Future<void> Function(AnalysisUpdate) onUpdate,
  }) {
    if (_closing != null || _handle == 0) {
      throw StateError('Analyzer is closed');
    }
    final document = pages.document;
    final snapshot = List<PageDescriptor>.unmodifiable(pages.pages);
    final job = AnalysisJob._(this, pages, document, onUpdate);
    job._start({
      'schema_version': 0,
      'document': document.toJson(),
      'pages': snapshot.map((p) => p.toJson()).toList(),
      'options': options.toJson(),
    });
    _jobs.add(job);
    return job;
  }

  AnalysisJob analyzePage({
    required PageDescriptor page,
    required AnalysisOptions options,
    required Future<PageInput> Function(PageRequest) loadPage,
    required Future<void> Function(AnalysisUpdate) onUpdate,
  }) => analyzeDocument(
    pages: _OnePage(page, loadPage),
    options: options,
    onUpdate: onUpdate,
  );
  Future<void> dispose() {
    _canWait(this);
    return _closing ??= _dispose();
  }

  Future<void> _dispose() async {
    for (final job in _jobs.toList()) {
      job.cancel();
    }
    final id = _handle;
    try {
      await Future.wait(
        _jobs.toList().map((j) => j._completion.future),
        eagerError: false,
      );
    } finally {
      try {
        await _closeAnalyzerAsync(id);
      } finally {
        _handle = 0;
        _handleFinalizer.detach(this);
        await _releaseAsync(id);
      }
    }
  }
}

class _OnePage implements PageSource {
  final PageDescriptor page;
  final Future<PageInput> Function(PageRequest) loader;
  _OnePage(this.page, this.loader);
  @override
  DocumentRef get document => page.key.document;
  @override
  List<PageDescriptor> get pages => [page];
  @override
  Future<PageInput> loadPage(PageRequest request) => loader(request);
}

JsonObject _failure(String code, Object error) {
  final message = error.toString();
  return {
    'code': error is PodocoException && error.code == 'source_changed'
        ? 'source_changed'
        : code,
    'message': message.length > 2048 ? message.substring(0, 2048) : message,
  };
}

/// Eager job with independent source, serial result, and control pumps. Done is
/// authoritative after native drain, late renders, leases, and wake notifications.
class AnalysisJob {
  final Analyzer _analyzer;
  PageSource? _source;
  Future<void> Function(AnalysisUpdate)? _sink;
  final DocumentRef _document;
  final CancellationToken _cancellation = CancellationToken();
  final Completer<AnalysisOutcome> _completion = Completer();
  late final NativeCallable<Void Function(Uint64)> _wake;
  Timer? _timer;
  Future<void>? _renderTask;
  int _handle = 0, _wakeReceived = 0, _wakeExpected = 0;
  int? _lastSequence;
  String? _analysisId;
  AnalysisProgress? _latest;
  AnalysisOutcome? _outcome;
  Object? _fatalError;
  StackTrace? _fatalStack;
  bool _nativeDrained = false;
  bool _rendering = false,
      _delivering = false,
      _driving = false,
      _finished = false;
  AnalysisJob._(this._analyzer, this._source, this._document, this._sink) {
    _completion.future.ignore();
    _wake = NativeCallable<Void Function(Uint64)>.listener((int token) {
      _wakeReceived++;
      _drive();
    });
  }
  void _start(JsonObject metadata) {
    try {
      _handle = using(
        (arena) => _newHandle(
          (out, error) => native.podoco_job_start(
            _analyzer._handle,
            _jsonBytes(arena, metadata),
            _wake.nativeFunction,
            0,
            out,
            error,
          ),
        ),
      );
    } catch (_) {
      _wake.close();
      rethrow;
    }
    _handleFinalizer.attach(this, _handle, detach: this);
    _timer = Timer.periodic(const Duration(milliseconds: 20), (_) => _drive());
    _drive();
  }

  /// Unique opaque analysis identity, including retries.
  String get id =>
      _analysisId ?? (throw StateError('Native job identity unavailable'));
  Future<AnalysisOutcome> get done {
    _canWait(_analyzer);
    return _completion.future;
  }

  AnalysisProgress? get latestProgress => _latest;

  /// Coalesced snapshots. A paused listener retains at most one yielded value;
  /// native completion and delivery do not depend on this optional stream.
  Stream<AnalysisProgress> get progress async* {
    while (true) {
      final snapshot = _latest;
      if (snapshot != null) yield snapshot;
      if (_finished) break;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  void cancel() {
    if (_finished) return;
    _cancellation._cancel();
    if (_handle != 0) {
      _control((error) => native.podoco_job_cancel(_handle, error));
    }
  }

  Future<void> dispose() async {
    _canWait(_analyzer);
    cancel();
    await _completion.future;
  }

  void _drive() {
    if (_handle == 0 || _finished || _driving) return;
    _driving = true;
    try {
      if (_fatalError != null) {
        using((arena) {
          final count = arena<Uint64>(), error = arena<Uint64>();
          if (_check(
                native.podoco_job_drain_state(_handle, count, error),
                error,
              ) ==
              native.PODOCO_OK) {
            _nativeDrained = true;
            _wakeExpected = count.value;
          }
        });
      } else if (_outcome == null) {
        final progress = _poll(
          (out, error) => native.podoco_job_progress(_handle, out, error),
        )!;
        _schema(progress);
        _analysisId ??= _text(progress['analysis_id']);
        _latest = AnalysisProgress._(_map(progress['progress']));
        if (progress['stopping'] as bool) _cancellation._cancel();
        final finished = _poll(
          (out, error) => native.podoco_job_outcome(_handle, out, error),
        );
        if (finished != null) {
          _schema(finished);
          _nativeDrained = true;
          _outcome = AnalysisOutcome.fromJson(_map(finished['outcome']));
          _latest = _outcome!.progress;
          _wakeExpected = _uint(finished['wake_count']);
          if (_outcome!.status == CompletionStatus.failed ||
              _outcome!.status == CompletionStatus.cancelled) {
            _cancellation._cancel();
          }
        }
      }
      if (_outcome == null && _fatalError == null) {
        if (!_rendering) {
          final request = _poll(
            (out, error) => native.podoco_source_next(_handle, out, error),
          );
          if (request != null) {
            _schema(request);
            _rendering = true;
            _renderTask = _render(request);
            unawaited(_renderTask!);
          }
        }
        if (!_delivering && _fatalError == null) {
          final result = _poll(
            (out, error) => native.podoco_result_next(_handle, out, error),
            maxBytes: _analyzer.options.limits.maxUpdateBytes,
          );
          if (result != null) {
            _delivering = true;
            unawaited(_deliver(result));
          }
        }
      }
      _finishIfDrained();
    } catch (e, s) {
      _failTransport(e, s);
    } finally {
      _driving = false;
    }
  }

  void _failTransport(Object error, StackTrace stack) {
    if (_fatalError != null) return;
    _fatalError = error;
    _fatalStack = stack;
    _cancellation._cancel();
    if (_handle != 0) {
      _control((out) => native.podoco_job_abandon(_handle, out));
    }
  }

  Future<void> _render(JsonObject request) async {
    PageInput? input;
    int? token;
    try {
      token = _uint(request['token']);
      final source = _source!;
      if (source.document != _document) {
        throw const PodocoException(
          'source_changed',
          'Document revision changed before rendering',
        );
      }
      final rendered = await runZoned(
        () => source.loadPage(PageRequest._(request, _cancellation)),
        zoneValues: {_callbackOwner: _analyzer},
      );
      input = rendered;
      if (source.document != _document) {
        throw const PodocoException(
          'source_changed',
          'Document revision changed during rendering',
        );
      }
      if (_fatalError == null) {
        if (rendered.image.isDisposed) {
          throw StateError('Source returned a disposed image');
        }
        using(
          (arena) => _control(
            (error) => native.podoco_source_reply(
              _handle,
              token!,
              rendered.image._handle,
              _jsonBytes(arena, rendered._metadata()),
              error,
            ),
          ),
        );
      }
    } catch (e, s) {
      if (token == null) {
        _failTransport(e, s);
      } else if (_fatalError == null) {
        try {
          using(
            (arena) => _control(
              (error) => native.podoco_source_fail(
                _handle,
                token!,
                _jsonBytes(arena, _failure('page_source', e)),
                error,
              ),
            ),
          );
        } catch (e, s) {
          _failTransport(e, s);
        }
      }
    } finally {
      try {
        await input?.image.dispose();
      } catch (e, s) {
        _failTransport(e, s);
      }
      _rendering = false;
      _drive();
    }
  }

  Future<void> _deliver(JsonObject raw) async {
    JsonObject? failure;
    int? sequence;
    try {
      sequence = _uint(raw['sequence']);
      final update = AnalysisUpdate.fromJson(raw);
      if (update.document != _document ||
          update.analysisId != id ||
          (_lastSequence != null && sequence <= _lastSequence!)) {
        throw const FormatException('Mismatched or unordered update');
      }
      // Do not acknowledge the terminal processing notice while the source
      // pump still owns an image-release notification. This keeps the Rust
      // scheduler's document boundary aligned with foreign allocation lifetime.
      if (update is DocumentFinished) {
        await _renderTask;
      }
      if (_fatalError != null) {
        throw StateError('Source transport cleanup failed');
      }
      await runZoned(
        () => _sink!(update),
        zoneValues: {_callbackOwner: _analyzer},
      );
      _lastSequence = sequence;
    } catch (e, s) {
      if (sequence == null) {
        _failTransport(e, s);
      }
      failure = _failure('delivery', e);
    }
    try {
      if (sequence != null) {
        using(
          (arena) => _control(
            (error) => native.podoco_result_ack(
              _handle,
              sequence!,
              failure == null ? _bytes(arena, []) : _jsonBytes(arena, failure),
              error,
            ),
          ),
        );
      }
    } catch (e, s) {
      _failTransport(e, s);
    } finally {
      _delivering = false;
      _drive();
    }
  }

  void _finishIfDrained() {
    if (!_nativeDrained ||
        _rendering ||
        _delivering ||
        _wakeReceived < _wakeExpected ||
        _finished) {
      return;
    }
    _finished = true;
    _timer?.cancel();
    _timer = null;
    // Native outcome freezes the count after every producer exits. Drain all
    // deferred scalar callbacks before closing their callable.
    _wake.close();
    final id = _handle;
    _handle = 0;
    _handleFinalizer.detach(this);
    native.podoco_release(id);
    _source = null;
    _sink = null;
    _renderTask = null;
    _analyzer._jobs.remove(this);
    if (_fatalError != null) {
      _completion.completeError(_fatalError!, _fatalStack);
    } else {
      _completion.complete(_outcome!);
    }
  }
}
