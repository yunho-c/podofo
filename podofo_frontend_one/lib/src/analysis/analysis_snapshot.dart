import 'package:podoco/podoco.dart' as podoco;

/// App-owned progressive state, distinct from SDK events. Initial layout events
/// never pretend to contain completed recognition; final page events reconcile it.
class AnalysisPageSnapshot {
  AnalysisPageSnapshot._({
    required this.analysisId,
    required this.sequence,
    required this.complete,
    this.projectedFromFormulaScope,
    required Map<String, Object?> page,
  }) : _pageJson = _immutable(page) as Map<String, Object?>,
       page = podoco.PageAnalysis.fromJson(page) {
    if (analysisId.isEmpty ||
        sequence < 0 ||
        (complete &&
            this.page.formulas.any((f) => f.state is podoco.FormulaPending))) {
      throw const FormatException('Invalid progressive page snapshot');
    }
    final pipeline = this.page.provenance.pipeline;
    if (projectedFromFormulaScope != null &&
        (complete || this.page.formulaScope != podoco.FormulaScope.none)) {
      throw const FormatException('Invalid layout projection');
    }
    for (final formula in this.page.formulas) {
      final provenance = switch (formula.state) {
        podoco.FormulaFinishedState(
          outcome: podoco.FormulaRecognized(:final formula),
        ) =>
          formula.provenance,
        podoco.FormulaFinishedState(
          outcome: podoco.FormulaTruncated(:final provenance),
        ) =>
          provenance,
        _ => null,
      };
      if (provenance != null &&
          (provenance.backend != pipeline.backend ||
              provenance.computePolicy != pipeline.computePolicy ||
              provenance.models.any(
                (model) => !pipeline.models.any(
                  (p) =>
                      p.modelId == model.modelId &&
                      p.manifestSha256 == model.manifestSha256,
                ),
              ))) {
        throw const FormatException(
          'Recognition provenance differs from its page pipeline',
        );
      }
    }
  }
  final String analysisId;
  final int sequence;
  final bool complete;

  /// Original execution scope when a preview projection omits recognition.
  /// App metadata, distinct from SDK page events and actual pipeline provenance.
  final podoco.FormulaScope? projectedFromFormulaScope;
  final podoco.PageAnalysis page;
  final Map<String, Object?> _pageJson;

  factory AnalysisPageSnapshot.fromJson(Map<String, Object?> j) =>
      AnalysisPageSnapshot._(
        analysisId: j['analysis_id'] as String,
        sequence: j['sequence'] as int,
        complete: j['complete'] as bool,
        projectedFromFormulaScope: switch (j['layout_projection_scope']) {
          null => null,
          'none' => podoco.FormulaScope.none,
          'all' => podoco.FormulaScope.all,
          _ => throw const FormatException('Invalid projection source scope'),
        },
        page: Map<String, Object?>.from(j['page'] as Map),
      );
  factory AnalysisPageSnapshot.fromUpdate(podoco.AnalysisUpdate update) {
    if (update is! podoco.PageLayoutReady && update is! podoco.PageFinished) {
      throw ArgumentError('A page snapshot starts with a layout or final page');
    }
    final payload = update.toJson()['payload'] as Map;
    return AnalysisPageSnapshot._(
      analysisId: update.analysisId,
      sequence: update.sequence,
      complete: update is podoco.PageFinished,
      page: Map<String, Object?>.from(payload['page'] as Map),
    );
  }
  Map<String, Object?> toJson() => {
    'analysis_id': analysisId,
    'sequence': sequence,
    'complete': complete,
    if (projectedFromFormulaScope != null)
      'layout_projection_scope': projectedFromFormulaScope!.name,
    'page': _pageJson,
  };

  AnalysisPageSnapshot merge(podoco.FormulaFinished update) {
    if (projectedFromFormulaScope != null ||
        update.analysisId != analysisId ||
        update.pageKey != page.page.key ||
        update.sequence <= sequence ||
        complete) {
      throw StateError('Formula update does not follow this partial page');
    }
    final previous = page.formulas
        .where((f) => f.regionId == update.regionId)
        .firstOrNull;
    if (previous?.state is! podoco.FormulaPending) {
      throw StateError('Formula update does not identify a pending region');
    }
    final outcome = (update.toJson()['payload'] as Map)['outcome'];
    final formulas = [
      for (final row in _pageJson['formulas'] as List)
        if ((row as Map)['region_id'] == update.regionId)
          {
            'region_id': update.regionId,
            'state': {'state': 'finished', 'outcome': outcome},
          }
        else
          row,
    ];
    return AnalysisPageSnapshot._(
      analysisId: analysisId,
      sequence: update.sequence,
      complete: false,
      page: {..._pageJson, 'formulas': formulas},
    );
  }
}

Object? _immutable(Object? value) => switch (value) {
  Map() => Map<String, Object?>.unmodifiable(
    value.map((k, v) => MapEntry(k as String, _immutable(v))),
  ),
  List() => List<Object?>.unmodifiable(value.map(_immutable)),
  _ => value,
};
