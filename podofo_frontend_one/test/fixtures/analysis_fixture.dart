import 'package:podoco/podoco.dart' as podoco;
import 'package:podofo_one/src/analysis/pdf_analysis_source.dart';

final fixtureManifest = 'a' * 64;
const fixtureProfile = 'app-lifecycle-fixture-v1';
podoco.AnalysisUpdate analysisFixture(
  podoco.DocumentRef document, {
  String analysisId = 'fixture-job',
  int pageIndex = 0,
  bool finished = false,
}) => podoco.AnalysisUpdate.fromJson({
  'schema_version': 0,
  'analysis_id': analysisId,
  'document': document.toJson(),
  'sequence': finished ? 1 : 0,
  'payload': {
    'type': finished ? 'page_finished' : 'page_layout_ready',
    'page': {
      'page': {
        'key': podoco.PageKey(document, pageIndex).toJson(),
        'space': [260, 360],
      },
      'provenance': {
        'pipeline': {
          'sdk_version': '0.1.0',
          'backend': 'test',
          'compute_policy': 'cpu_only',
          'adapter': 'app-fixture',
          'profile': fixtureProfile,
          'models': [
            {
              'model_id': 'fixture',
              'manifest_sha256': fixtureManifest,
              'artifacts': {'fixture': 'b' * 64},
            },
          ],
        },
        'render_profile': layoutRenderProfile,
        'image': {
          'width': 260,
          'height': 360,
          'row_stride': 1040,
          'format': 'bgra8',
          'alpha': 'opaque',
        },
        'pixel_to_page': [1, 0, 0, 1, 0, 0],
      },
      'formula_scope': 'none',
      'regions': [],
      'formulas': [],
      'reading_order': null,
      'diagnostics': [],
    },
  },
});
