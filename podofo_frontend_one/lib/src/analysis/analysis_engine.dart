import 'package:podoco/podoco.dart' as podoco;
import 'package:podoco_flutter/podoco_flutter.dart';
import 'package:podoco_app_models/app_models.dart';

import 'preview_layout_store.dart';

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
  DocumentAnalysisJob analyzePage(
    podoco.PageSource pages,
    int pageIndex,
    Future<void> Function(podoco.AnalysisUpdate) sink, {
    podoco.FormulaScope formulaScope = podoco.FormulaScope.none,
  });
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
  static Future<AnalysisEngine> openBundled(void Function(String) progress) =>
      _openBundled(progress, true);

  static Future<AnalysisEngine> openBundledLayout(
    void Function(String) progress,
  ) => _openBundled(progress, false);

  static Future<AnalysisEngine> _openBundled(
    void Function(String) progress,
    bool includeFormula,
  ) async => NativeAnalysisEngine._(
    await FlutterPodoco.openAnalyzer(
      pack: AppAnalysisPacks.documentAnalysis,
      options: _options(includeFormula),
      includeFormula: includeFormula,
      onProgress: (value) => progress(analysisPreparationText(value)),
    ),
  );

  static podoco.AnalyzerOptions _options(bool formula) =>
      podoco.AnalyzerOptions(
        computePolicy: podoco.ComputePolicy.cpuAndNeuralEngine,
        limits: podoco.ResourceLimits(
          queuedJobs: 2,
          inputBytes: 16 * 1024 * 1024,
          pendingUpdates: 2,
          resultBytes: 4 * 1024 * 1024,
          maxUpdateBytes: 2 * 1024 * 1024,
          tensorBytes: 128 * 1024 * 1024,
          decoderCacheBytes: formula ? 48 * 1024 * 1024 : 1,
        ),
      );
  static Future<AnalysisEngine> open(AnalysisModelPaths paths) async {
    final bundle = await podoco.ModelBundle.verify(paths.layout);
    final formula = paths.formula == null
        ? null
        : await podoco.FormulaBundle.verify(paths.formula!);
    return NativeAnalysisEngine._(
      await podoco.Analyzer.open(
        bundle,
        formulaBundle: formula,
        options: _options(formula != null),
      ),
    );
  }

  static Future<PreviewLayoutProfile> previewProfile(
    AnalysisModelPaths? paths, {
    String? customFormulaManifest,
  }) async {
    if (paths == null) {
      final identity = await const FlutterModelLoader().readLayoutIdentity(
        AppAnalysisPacks.documentAnalysis,
      );
      return PreviewLayoutProfile(
        layoutManifest: identity.manifestSha256,
        layoutModelId: identity.modelId,
        layoutProfile: identity.profile,
        layoutAdapter: identity.adapter,
        backend: identity.backend,
        formulaManifest: identity.pack.manifestHashes['formula'],
        computePolicy: podoco.ComputePolicy.cpuAndNeuralEngine,
      );
    }
    // Custom model directories have no application-pinned catalog. Keep their
    // full bundle verification rather than trusting arbitrary manifest metadata.
    final layout = await podoco.ModelBundle.verify(paths.layout);
    return PreviewLayoutProfile(
      layoutManifest: layout.manifestSha256,
      layoutModelId: layout.id,
      layoutProfile: layout.profile,
      formulaManifest: customFormulaManifest,
      computePolicy: podoco.ComputePolicy.cpuAndNeuralEngine,
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
  DocumentAnalysisJob analyzePage(
    podoco.PageSource pages,
    int pageIndex,
    Future<void> Function(podoco.AnalysisUpdate) sink, {
    podoco.FormulaScope formulaScope = podoco.FormulaScope.none,
  }) => _NativeDocumentAnalysisJob(
    _analyzer.analyzePage(
      page: pages.pages[pageIndex],
      loadPage: pages.loadPage,
      onUpdate: sink,
      options: podoco.AnalysisOptions(
        profile: profile,
        formulaScope: formulaScope,
        requireReadingOrder: true,
      ),
    ),
  );

  @override
  Future<void> close() => _analyzer.dispose();
}

String analysisPreparationText(ModelLoadProgress progress) =>
    switch (progress.stage) {
      ModelLoadStage.locating => 'Locating bundled analysis assets…',
      ModelLoadStage.verifying => 'Verifying ${progress.component} assets…',
      ModelLoadStage.opening =>
        progress.component == 'math'
            ? 'Preparing equation speech…'
            : 'Opening document analysis…',
    };

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
