import 'package:podoco/podoco.dart' as podoco;

import 'analysis_store.dart';
import 'pdf_analysis_source.dart';

/// Explicit compatibility between layout-only and the committed combined
/// pipeline. The stored snapshot keeps its actual provenance unchanged.
class PreviewLayoutProfile {
  const PreviewLayoutProfile({
    required this.layoutManifest,
    required this.layoutProfile,
    required this.computePolicy,
    this.formulaManifest,
    this.backend = 'coreml',
    this.layoutModelId,
    this.layoutAdapter = 'pp-doclayout-v3-v1',
    this.combinedAdapter = 'pp-doclayout-v3-formulanet-plus-l-v1',
    this.combinedProfile = 'pp-doclayout-v3-formulanet-plus-l-greedy2048-v1',
  });
  final String layoutManifest, layoutProfile, layoutAdapter;
  final String? formulaManifest;
  final String backend;
  final String? layoutModelId;
  final String combinedAdapter, combinedProfile;
  final podoco.ComputePolicy computePolicy;

  bool accepts(AnalysisPageSnapshot snapshot) {
    final provenance = snapshot.page.provenance;
    final pipeline = provenance.pipeline;
    if (provenance.renderProfile != layoutRenderProfile ||
        pipeline.backend != backend ||
        pipeline.computePolicy != computePolicy ||
        pipeline.models.isEmpty ||
        pipeline.models.first.manifestSha256 != layoutManifest ||
        (layoutModelId != null &&
            pipeline.models.first.modelId != layoutModelId)) {
      return false;
    }
    return (pipeline.models.length == 1 &&
            pipeline.profile == layoutProfile &&
            pipeline.adapter == layoutAdapter) ||
        (formulaManifest != null &&
            pipeline.models.length == 2 &&
            pipeline.models[1].manifestSha256 == formulaManifest &&
            pipeline.profile == combinedProfile &&
            pipeline.adapter == combinedAdapter);
  }

  Iterable<String> keys(podoco.DocumentRef document) sync* {
    yield analysisCacheKey(
      document,
      [layoutManifest],
      layoutProfile,
      computePolicy,
    );
    if (formulaManifest != null) {
      yield analysisCacheKey(
        document,
        [layoutManifest, formulaManifest!],
        combinedProfile,
        computePolicy,
      );
    }
  }
}

/// Layout projections live outside the manual/formula-analysis namespace.
class PreviewLayoutStore extends AnalysisStore {
  PreviewLayoutStore(
    super.directory, {
    super.maxBytes = 16 * 1024 * 1024,
    super.maxPageBytes = 4 * 1024 * 1024,
  });

  Future<AnalysisPageSnapshot?> readCompatible(
    podoco.DocumentRef document,
    int pageIndex,
    PreviewLayoutProfile profile,
  ) async {
    for (final key in profile.keys(document)) {
      final snapshot = await read(key, pageIndex, document);
      if (snapshot != null &&
          snapshot.projectedFromFormulaScope != null &&
          profile.accepts(snapshot)) {
        return snapshot;
      }
    }
    return null;
  }

  Future<AnalysisPageSnapshot?> publish(
    AnalysisPageSnapshot snapshot,
    PreviewLayoutProfile profile,
    bool Function() isCurrent,
  ) {
    if (!profile.accepts(snapshot) || !isCurrent()) return Future.value(null);
    final json = snapshot.toJson();
    final projection = AnalysisPageSnapshot.fromJson({
      ...json,
      'complete': false,
      'layout_projection_scope':
          (snapshot.projectedFromFormulaScope ?? snapshot.page.formulaScope)
              .name,
      'page': {
        ...(json['page'] as Map),
        'formula_scope': 'none',
        'formulas': [
          for (final region in snapshot.page.regions.where(
            (r) => r.category == podoco.RegionCategory.formula,
          ))
            {
              'region_id': region.id,
              'state': {'state': 'not_requested'},
            },
        ],
      },
    });
    final pipeline = projection.page.provenance.pipeline;
    return writeSnapshot(
      analysisCacheKey(
        projection.page.page.key.document,
        pipeline.models.map((m) => m.manifestSha256).toList(),
        pipeline.profile,
        pipeline.computePolicy,
      ),
      projection,
      isCurrent,
    );
  }
}
