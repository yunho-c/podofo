import 'dart:convert';

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

podoco.AnalysisUpdate formulaFixture(
  podoco.DocumentRef document, {
  int stage = 0,
  String analysisId = 'formula-job',
  String latex = r'\frac{x+1}{2}',
  String? formulaManifest,
}) {
  final json = jsonDecode(
    jsonEncode(analysisFixture(document, analysisId: analysisId).toJson()),
  ) as Map<String, dynamic>;
  json['sequence'] = stage;
  final page = json['payload']['page'] as Map<String, dynamic>;
  final pipeline = page['provenance']['pipeline'] as Map<String, dynamic>;
  if (formulaManifest != null) {
    (pipeline['models'] as List).add({
      'model_id': 'recognizer',
      'manifest_sha256': formulaManifest,
      'artifacts': {'fixture': 'b' * 64},
    });
  }
  final outcome = {
    'status': 'recognized',
    'formula': {
      'latex': latex,
      'display_kind': 'displayed',
      'score': null,
      'provenance': pipeline,
    },
  };
  page['formula_scope'] = 'all';
  page['regions'] = [
    {
      'id': 17,
      'model_class_id': 5,
      'category': 'formula',
      'model_label': 'formula',
      'native_subtype': null,
      'display_kind': 'displayed',
      'bounds': [20, 25, 180, 75],
      'polygon': null,
      'score': 0.9,
      'diagnostics': [],
    },
  ];
  page['formulas'] = [
    {
      'region_id': 17,
      'state': stage == 2
          ? {'state': 'finished', 'outcome': outcome}
          : {'state': 'pending'},
    },
  ];
  if (stage == 1) {
    json['payload'] = {
      'type': 'formula_finished',
      'page_key': podoco.PageKey(document, 0).toJson(),
      'region_id': 17,
      'outcome': outcome,
    };
  } else if (stage == 2) {
    json['payload']['type'] = 'page_finished';
  }
  return podoco.AnalysisUpdate.fromJson(json);
}
