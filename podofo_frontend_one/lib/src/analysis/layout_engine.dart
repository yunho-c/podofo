import 'package:podoco/podoco.dart' as podoco;

/// Application seam for lifecycle tests; execution is always in Podoco in the app.
abstract interface class LayoutEngine {
  String get profile;
  String get manifest;
  LayoutJob analyze(
    podoco.PageSource pages,
    Future<void> Function(podoco.AnalysisUpdate) sink,
  );
  Future<void> close();
}

abstract interface class LayoutJob {
  String get id;
  Future<podoco.AnalysisOutcome> get done;
  Stream<podoco.AnalysisProgress> get progress;
  void cancel();
}

class NativeLayoutEngine implements LayoutEngine {
  NativeLayoutEngine._(this._analyzer, this.manifest);
  final podoco.Analyzer _analyzer;
  @override
  final String manifest;
  @override
  String get profile => _analyzer.profile;
  static Future<LayoutEngine> open(String directory) async {
    final bundle = await podoco.ModelBundle.verify(directory);
    return NativeLayoutEngine._(
      await podoco.Analyzer.open(
        bundle,
        options: podoco.AnalyzerOptions(
          computePolicy: podoco.ComputePolicy.cpuAndNeuralEngine,
          limits: podoco.ResourceLimits(
            queuedJobs: 2,
            inputBytes: 16 * 1024 * 1024,
            pendingUpdates: 2,
            resultBytes: 512 * 1024,
            maxUpdateBytes: 256 * 1024,
            tensorBytes: 96 * 1024 * 1024,
            decoderCacheBytes: 1,
          ),
        ),
      ),
      bundle.manifestSha256,
    );
  }

  @override
  LayoutJob analyze(
    podoco.PageSource pages,
    Future<void> Function(podoco.AnalysisUpdate) sink,
  ) => _NativeLayoutJob(
    _analyzer.analyzeDocument(
      pages: pages,
      onUpdate: sink,
      options: podoco.AnalysisOptions(
        profile: profile,
        formulaScope: podoco.FormulaScope.none,
        requireReadingOrder: true,
      ),
    ),
  );
  @override
  Future<void> close() => _analyzer.dispose();
}

class _NativeLayoutJob implements LayoutJob {
  _NativeLayoutJob(this.job);
  final podoco.AnalysisJob job;
  @override
  String get id => job.id;
  @override
  Future<podoco.AnalysisOutcome> get done => job.done;
  @override
  Stream<podoco.AnalysisProgress> get progress => job.progress;
  @override
  void cancel() => job.cancel();
}
