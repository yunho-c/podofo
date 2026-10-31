import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:pdfrx/pdfrx.dart';
import 'package:podoco/podoco.dart' as podoco;
import 'package:podofo_one/src/analysis/analysis_snapshot.dart';
import 'package:podofo_one/src/analysis/pdf_analysis_source.dart';
import 'package:podofo_one/src/previews/link_target.dart';
import 'package:podofo_one/src/services/pdf_session.dart';

import '../fixtures/analysis_fixture.dart';
import 'target_preview_metrics.dart';

/// Hand annotations are deliberately labeled as fixture provenance. They may
/// exercise grouping rules but cannot establish model detection quality.
class ComplexPreviewFixture {
  final Map<String, dynamic> manifest = jsonDecode(
    File('test/fixtures/target_preview/complex_objects.json')
        .readAsStringSync(),
  );
  List<dynamic> get cases => manifest['cases'] as List;
  Map<String, dynamic> entry(String id) =>
      Map<String, dynamic>.from(cases.singleWhere((c) => c['id'] == id));

  podoco.AnalysisUpdate update(
    PdfSession session,
    int page, {
    String analysisId = 'fixture-job',
  }) => updateForDocument(
    analysisDocumentRef(session),
    page,
    analysisId: analysisId,
  );

  podoco.AnalysisUpdate updateForDocument(
    podoco.DocumentRef document,
    int page, {
    String analysisId = 'fixture-job',
  }) {
    final annotation = manifest['pages'][page - 1];
    final json = jsonDecode(
      jsonEncode(
        analysisFixture(
          document,
          pageIndex: page - 1,
          analysisId: analysisId,
        ).toJson(),
      ),
    );
    final data = json['payload']['page'];
    data['page']['space'] = annotation['size'];
    final width = annotation['size'][0] as int,
        height = annotation['size'][1] as int;
    data['provenance']['image'] = {
      'width': width,
      'height': height,
      'row_stride': width * 4,
      'format': 'bgra8',
      'alpha': 'opaque',
    };
    data['regions'] = [
      for (final r in annotation['regions'])
        {
          'id': r['id'],
          'model_class_id': 0,
          'model_label': 'hand-annotated-fixture',
          'category': r['category'] == 'formulaNumber'
              ? 'formula_number'
              : r['category'],
          'native_subtype': r['native_subtype'],
          'bounds': r['bounds'],
          'display_kind': r['category'] == 'formula' ? 'displayed' : null,
          'polygon': null,
          'score': 1.0,
          'diagnostics': [],
        },
    ];
    data['formulas'] = [
      for (final r in annotation['regions'])
        if (r['category'] == 'formula')
          {
            'region_id': r['id'],
            'state': {'state': 'not_requested'},
          },
    ];
    return podoco.AnalysisUpdate.fromJson(Map<String, Object?>.from(json));
  }

  AnalysisPageSnapshot snapshot(PdfSession session, int page) =>
      AnalysisPageSnapshot.fromUpdate(update(session, page));

  Future<LinkPreviewRequest> request(
    PdfSession session,
    String id, {
    Size maxSize = semanticPreviewMaxSize,
  }) async {
    final c = entry(id), page = session.lease.document.pages.first;
    final links = await page.loadLinks();
    final center = previewFixtureRect(c['source_bounds']).center;
    final index = links.indexWhere(
      (l) => (l.rects.single.toRect(page: page).center - center).distance < .1,
    );
    final link = links[index];
    return LinkPreviewRequest(
      session: session,
      sourcePage: 1,
      annotationIndex: index,
      sourceRects: link.rects,
      destination: link.dest!,
      pixelRatio: 2,
      maxSize: maxSize,
    );
  }
}
