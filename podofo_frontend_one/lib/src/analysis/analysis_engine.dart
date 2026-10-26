import 'package:podoco/podoco.dart' as podoco;

class AnalysisModelPaths {
  const AnalysisModelPaths(this.layout, {this.formula});
  final String layout;
  final String? formula;
}

/// Application seam for lifecycle tests; execution is always in Podoco in the app.
abstract interface class AnalysisEngine {
  String get profile;
  List<String> get manifests;
  podoco.ComputePolicy get computePolicy;
  bool get recognizesFormulas;
  DocumentAnalysisJob analyze(
    podoco.PageSource pages,
    Future<void> Function(podoco.AnalysisUpdate) sink,
  );
  Future<void> close();
}

abstract interface class DocumentAnalysisJob {
  String get id;
  Future<podoco.AnalysisOutcome> get done;
  Stream<podoco.AnalysisProgress> get progress;
  void cancel();
}

class NativeAnalysisEngine implements AnalysisEngine {
  NativeAnalysisEngine._(this._analyzer);
  final podoco.Analyzer _analyzer;
  @override
  List<String> get manifests => _analyzer.modelManifests;
  @override
  podoco.ComputePolicy get computePolicy => _analyzer.options.computePolicy;
  @override
  bool get recognizesFormulas => _analyzer.capabilities.formulaRecognition;
  @override
  String get profile => _analyzer.profile;
  static Future<AnalysisEngine> open(AnalysisModelPaths paths) async {
    final bundle = await podoco.ModelBundle.verify(paths.layout);
    final formula = paths.formula == null
        ? null
        : await podoco.FormulaBundle.verify(paths.formula!);
    return NativeAnalysisEngine._(
      await podoco.Analyzer.open(
        bundle,
        formulaBundle: formula,
        options: podoco.AnalyzerOptions(
          computePolicy: podoco.ComputePolicy.cpuAndNeuralEngine,
          limits: podoco.ResourceLimits(
            queuedJobs: 2,
            inputBytes: 16 * 1024 * 1024,
            pendingUpdates: 2,
            resultBytes: 4 * 1024 * 1024,
            maxUpdateBytes: 2 * 1024 * 1024,
            tensorBytes: 128 * 1024 * 1024,
            decoderCacheBytes: formula == null ? 1 : 48 * 1024 * 1024,
          ),
        ),
      ),
    );
  }

  @override
  DocumentAnalysisJob analyze(
    podoco.PageSource pages,
    Future<void> Function(podoco.AnalysisUpdate) sink,
  ) => _NativeDocumentAnalysisJob(
    _analyzer.analyzeDocument(
      pages: pages,
      onUpdate: sink,
      options: podoco.AnalysisOptions(
        profile: profile,
        formulaScope: recognizesFormulas
            ? podoco.FormulaScope.all
            : podoco.FormulaScope.none,
        requireReadingOrder: true,
      ),
    ),
  );
  @override
  Future<void> close() => _analyzer.dispose();
}

class _NativeDocumentAnalysisJob implements DocumentAnalysisJob {
  _NativeDocumentAnalysisJob(this.job);
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
