part of 'analysis.dart';

/// Owned semantic JSON; images and native pointers never enter this format.
typedef JsonObject = Map<String, Object?>;
JsonObject _map(Object? value) => Map<String, Object?>.from(value as Map);
List<Object?> _list(Object? value) => List<Object?>.from(value as List);
String _text(Object? value) {
  final s = value as String;
  if (s.trim().isEmpty) throw const FormatException('Empty identity');
  return s;
}

int _uint(Object? value) {
  final n = value as int;
  if (n < 0) throw const FormatException('Negative count');
  return n;
}

int _u32(Object? value) {
  final n = _uint(value);
  if (n > 0xffffffff) throw const FormatException('Count exceeds uint32');
  return n;
}

double _number(Object? value) {
  final n = (value as num).toDouble();
  if (!n.isFinite) throw const FormatException('Non-finite number');
  return n;
}

T _enum<T extends Enum>(List<T> values, Object? name) => values.firstWhere(
  (v) => _snake(v.name) == name,
  orElse: () => throw FormatException('Unknown required variant: $name'),
);
String _sha(Object? value) {
  final hash = _text(value);
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) {
    throw const FormatException('Invalid SHA-256');
  }
  return hash;
}

String _snake(String name) =>
    name.replaceAllMapped(RegExp('[A-Z]'), (m) => '_${m[0]!.toLowerCase()}');
void _schema(JsonObject value) {
  if (value['schema_version'] != 0) {
    throw const FormatException('Unsupported Podoco schema');
  }
}

Object? _freeze(Object? value) => switch (value) {
  Map() => Map<String, Object?>.unmodifiable(
    value.map((k, v) => MapEntry(k as String, _freeze(v))),
  ),
  List() => List<Object?>.unmodifiable(value.map(_freeze)),
  _ => value,
};

/// Owned native or callback diagnostic with a stable category.
class PodocoException implements Exception {
  final String code;
  final String message;
  const PodocoException(this.code, this.message);
  factory PodocoException.fromJson(JsonObject j) =>
      PodocoException(_text(j['code']), j['message'] as String);
  JsonObject toJson() => {'code': code, 'message': message};
  @override
  String toString() => 'PodocoException($code): $message';
}

class DocumentRef {
  final String id, revision;
  DocumentRef(this.id, this.revision) {
    _text(id);
    _text(revision);
  }
  factory DocumentRef.fromJson(JsonObject j) =>
      DocumentRef(_text(j['id']), _text(j['revision']));
  JsonObject toJson() => {'id': id, 'revision': revision};
  @override
  bool operator ==(Object other) =>
      other is DocumentRef && other.id == id && other.revision == revision;
  @override
  int get hashCode => Object.hash(id, revision);
}

class PageKey {
  final DocumentRef document;
  final int pageIndex;
  PageKey(this.document, this.pageIndex) {
    if (pageIndex < 0 || pageIndex > 0xffffffff) {
      throw ArgumentError('pageIndex must fit uint32');
    }
  }
  factory PageKey.fromJson(JsonObject j) => PageKey(
    DocumentRef.fromJson(_map(j['document'])),
    _uint(j['page_index']),
  );
  JsonObject toJson() => {
    'document': document.toJson(),
    'page_index': pageIndex,
  };
  @override
  bool operator ==(Object other) =>
      other is PageKey &&
      other.document == document &&
      other.pageIndex == pageIndex;
  @override
  int get hashCode => Object.hash(document, pageIndex);
}

class PageSpace {
  final double width, height;
  PageSpace(this.width, this.height) {
    if (!width.isFinite || !height.isFinite || width <= 0 || height <= 0) {
      throw ArgumentError('Invalid page space');
    }
  }
  factory PageSpace.fromJson(Object? value) {
    final a = _list(value);
    if (a.length != 2) throw const FormatException('Invalid page dimensions');
    return PageSpace(_number(a[0]), _number(a[1]));
  }
  List<double> toJson() => [width, height];
}

class PageDescriptor {
  final PageKey key;
  final PageSpace space;
  const PageDescriptor(this.key, this.space);
  factory PageDescriptor.fromJson(JsonObject j) => PageDescriptor(
    PageKey.fromJson(_map(j['key'])),
    PageSpace.fromJson(j['space']),
  );
  JsonObject toJson() => {'key': key.toJson(), 'space': space.toJson()};
}

class Affine {
  final List<double> values;
  Affine(Iterable<double> values) : values = List.unmodifiable(values) {
    if (this.values.length != 6 || this.values.any((n) => !n.isFinite)) {
      throw ArgumentError('Invalid affine');
    }
    final v = this.values, determinant = v[0] * v[3] - v[1] * v[2];
    if (!determinant.isFinite || determinant == 0) {
      throw ArgumentError('Singular affine');
    }
    final inverse = [
      v[3] / determinant,
      -v[1] / determinant,
      -v[2] / determinant,
      v[0] / determinant,
      (v[2] * v[5] - v[3] * v[4]) / determinant,
      (v[1] * v[4] - v[0] * v[5]) / determinant,
    ];
    if (inverse.any((n) => !n.isFinite)) {
      throw ArgumentError('Non-finite affine inverse');
    }
  }
  factory Affine.identity() => Affine([1, 0, 0, 1, 0, 0]);
  factory Affine.fromJson(Object? j) => Affine(_list(j).map(_number));
  List<double> toJson() => values;
}

class PageRect {
  final double left, top, right, bottom;
  PageRect(this.left, this.top, this.right, this.bottom) {
    if ([
          left,
          top,
          right,
          bottom,
          right - left,
          bottom - top,
        ].any((n) => !n.isFinite) ||
        right <= left ||
        bottom <= top) {
      throw ArgumentError('Invalid rectangle');
    }
  }
  factory PageRect.fromJson(Object? j) {
    final a = _list(j);
    if (a.length != 4) throw const FormatException('Invalid rectangle');
    return PageRect(_number(a[0]), _number(a[1]), _number(a[2]), _number(a[3]));
  }
}

enum PixelFormat { bgra8, rgba8 }

enum AlphaMode { opaque, straight, premultiplied }

class ImageDescriptor {
  final int width, height, rowStride;
  final PixelFormat format;
  final AlphaMode alpha;
  ImageDescriptor({
    required this.width,
    required this.height,
    required this.rowStride,
    required this.format,
    required this.alpha,
  }) {
    if (width <= 0 ||
        height <= 0 ||
        width > 0xffffffff ||
        height > 0xffffffff ||
        rowStride < width * 4) {
      throw ArgumentError('Invalid image descriptor');
    }
  }
  factory ImageDescriptor.fromJson(JsonObject j) => ImageDescriptor(
    width: _uint(j['width']),
    height: _uint(j['height']),
    rowStride: _uint(j['row_stride']),
    format: _enum(PixelFormat.values, j['format']),
    alpha: _enum(AlphaMode.values, j['alpha']),
  );
  JsonObject toJson() => {
    'width': width,
    'height': height,
    'row_stride': rowStride,
    'format': format.name,
    'alpha': alpha.name,
  };
}

enum ComputePolicy { cpuOnly, cpuAndNeuralEngine, all }

enum FormulaScope { all, none }

class ResourceLimits {
  final int queuedJobs,
      inputBytes,
      pendingUpdates,
      resultBytes,
      maxUpdateBytes,
      tensorBytes,
      decoderCacheBytes;
  ResourceLimits({
    required this.queuedJobs,
    required this.inputBytes,
    required this.pendingUpdates,
    required this.resultBytes,
    required this.maxUpdateBytes,
    required this.tensorBytes,
    required this.decoderCacheBytes,
  }) {
    if ([
          queuedJobs,
          inputBytes,
          pendingUpdates,
          resultBytes,
          maxUpdateBytes,
          tensorBytes,
          decoderCacheBytes,
        ].any((v) => v <= 0) ||
        queuedJobs > 0xffffffff ||
        pendingUpdates > 0xffffffff ||
        maxUpdateBytes > resultBytes) {
      throw ArgumentError('Invalid resource limits');
    }
  }
  JsonObject toJson() => {
    'queued_jobs': queuedJobs,
    'input_bytes': inputBytes,
    'pending_updates': pendingUpdates,
    'result_bytes': resultBytes,
    'max_update_bytes': maxUpdateBytes,
    'tensor_bytes': tensorBytes,
    'decoder_cache_bytes': decoderCacheBytes,
  };
}

class AnalyzerOptions {
  final ComputePolicy computePolicy;
  final ResourceLimits limits;
  const AnalyzerOptions({required this.computePolicy, required this.limits});
  JsonObject toJson() => {
    'compute_policy': _snake(computePolicy.name),
    'limits': limits.toJson(),
  };
}

class AnalysisOptions {
  final String profile;
  final FormulaScope formulaScope;
  final bool requirePolygons, requireReadingOrder;
  AnalysisOptions({
    required this.profile,
    this.formulaScope = FormulaScope.all,
    this.requirePolygons = false,
    this.requireReadingOrder = false,
  }) {
    _text(profile);
  }
  JsonObject toJson() => {
    'profile': profile,
    'formula_scope': formulaScope.name,
    'require_polygons': requirePolygons,
    'require_reading_order': requireReadingOrder,
  };
}

class Capabilities {
  final bool layout, formulaRecognition, polygons, readingOrder;
  Capabilities._(JsonObject j)
    : layout = j['layout'] as bool,
      formulaRecognition = j['formula_recognition'] as bool,
      polygons = j['polygons'] as bool,
      readingOrder = j['reading_order'] as bool;
}

class Diagnostic {
  final String code, message;
  Diagnostic._(JsonObject j)
    : code = _text(j['code']),
      message = j['message'] as String;
}

List<Diagnostic> _diagnostics(Object? j) =>
    List.unmodifiable(_list(j).map((v) => Diagnostic._(_map(v))));

class ModelProvenance {
  final String modelId, manifestSha256;
  final Map<String, String> artifacts;
  ModelProvenance._(JsonObject j)
    : modelId = _text(j['model_id']),
      manifestSha256 = _sha(j['manifest_sha256']),
      artifacts = Map.unmodifiable(
        _map(j['artifacts'])
            .map((key, value) => MapEntry(_text(key), _sha(value))),
      );
}

class PipelineProvenance {
  final String sdkVersion, backend, adapter, profile;
  final ComputePolicy computePolicy;
  final List<ModelProvenance> models;
  PipelineProvenance._(JsonObject j)
    : sdkVersion = _text(j['sdk_version']),
      backend = _text(j['backend']),
      adapter = _text(j['adapter']),
      profile = _text(j['profile']),
      computePolicy = _enum(ComputePolicy.values, j['compute_policy']),
      models = List.unmodifiable(
        _list(j['models']).map((v) => ModelProvenance._(_map(v))),
      ) {
    if (models.isEmpty || models.any((m) => m.artifacts.isEmpty)) {
      throw const FormatException('Missing model evidence');
    }
  }
}

class PageProvenance {
  final PipelineProvenance pipeline;
  final String renderProfile;
  final ImageDescriptor image;
  final Affine pixelToPage;
  PageProvenance._(JsonObject j)
    : pipeline = PipelineProvenance._(_map(j['pipeline'])),
      renderProfile = _text(j['render_profile']),
      image = ImageDescriptor.fromJson(_map(j['image'])),
      pixelToPage = Affine.fromJson(j['pixel_to_page']);
}

enum RegionCategory {
  text,
  heading,
  formula,
  formulaNumber,
  table,
  figure,
  caption,
  header,
  footer,
  other,
}

enum FormulaDisplayKind { inline, displayed, unknown }

double? _score(Object? j) {
  if (j == null) return null;
  final n = _number(j);
  if (n < 0 || n > 1) throw const FormatException('Invalid score');
  return n;
}

List<List<double>>? _polygon(Object? value) {
  if (value == null) return null;
  final points = _list(value)
      .map((v) => List<double>.unmodifiable(_list(v).map(_number)))
      .toList();
  if (points.length < 3 || points.any((p) => p.length != 2)) {
    throw const FormatException('Invalid polygon vertices');
  }
  final origin = points.first;
  var area = 0.0;
  for (var i = 0; i < points.length; i++) {
    final a = points[i], b = points[(i + 1) % points.length];
    area +=
        (a[0] - origin[0]) * (b[1] - origin[1]) -
        (b[0] - origin[0]) * (a[1] - origin[1]);
  }
  if (!area.isFinite || area == 0) {
    throw const FormatException('Degenerate polygon');
  }
  return List.unmodifiable(points);
}

class LayoutRegion {
  final int id, modelClassId;
  final RegionCategory category;
  final String modelLabel;
  final String? nativeSubtype;
  final FormulaDisplayKind? displayKind;
  final PageRect bounds;
  final List<List<double>>? polygon;
  final double? score;
  final List<Diagnostic> diagnostics;
  LayoutRegion._(JsonObject j)
    : id = _u32(j['id']),
      modelClassId = _u32(j['model_class_id']),
      category = _enum(RegionCategory.values, j['category']),
      modelLabel = _text(j['model_label']),
      nativeSubtype = j['native_subtype'] as String?,
      displayKind = j['display_kind'] == null
          ? null
          : _enum(FormulaDisplayKind.values, j['display_kind']),
      bounds = PageRect.fromJson(j['bounds']),
      polygon = _polygon(j['polygon']),
      score = _score(j['score']),
      diagnostics = _diagnostics(j['diagnostics']) {
    if ((category == RegionCategory.formula) != (displayKind != null)) {
      throw const FormatException('Invalid formula display context');
    }
  }
}

class RecognizedFormula {
  final String latex;
  final FormulaDisplayKind displayKind;
  final double? score;
  final PipelineProvenance provenance;
  RecognizedFormula._(JsonObject j)
    : latex = _text(j['latex']),
      displayKind = _enum(FormulaDisplayKind.values, j['display_kind']),
      score = _score(j['score']),
      provenance = PipelineProvenance._(_map(j['provenance']));
}

sealed class FormulaOutcome {
  const FormulaOutcome();
  factory FormulaOutcome.fromJson(JsonObject j) => switch (j['status']) {
    'recognized' => FormulaRecognized(RecognizedFormula._(_map(j['formula']))),
    'failed' => FormulaFailed(PodocoException.fromJson(_map(j['error']))),
    'truncated' => FormulaTruncated(
      j['partial_latex'] as String?,
      PodocoException.fromJson(_map(j['error'])),
      PipelineProvenance._(_map(j['provenance'])),
    ),
    _ => throw const FormatException('Unknown formula outcome'),
  };
}

final class FormulaRecognized extends FormulaOutcome {
  final RecognizedFormula formula;
  const FormulaRecognized(this.formula);
}

final class FormulaFailed extends FormulaOutcome {
  final PodocoException error;
  const FormulaFailed(this.error);
}

final class FormulaTruncated extends FormulaOutcome {
  final String? partialLatex;
  final PodocoException error;
  final PipelineProvenance provenance;
  const FormulaTruncated(this.partialLatex, this.error, this.provenance);
}

sealed class FormulaState {
  const FormulaState();
  factory FormulaState.fromJson(JsonObject j) => switch (j['state']) {
    'not_requested' => const FormulaNotRequested(),
    'pending' => const FormulaPending(),
    'finished' => FormulaFinishedState(
      FormulaOutcome.fromJson(_map(j['outcome'])),
    ),
    _ => throw const FormatException('Unknown formula state'),
  };
}

final class FormulaNotRequested extends FormulaState {
  const FormulaNotRequested();
}

final class FormulaPending extends FormulaState {
  const FormulaPending();
}

final class FormulaFinishedState extends FormulaState {
  final FormulaOutcome outcome;
  const FormulaFinishedState(this.outcome);
}

class FormulaResult {
  final int regionId;
  final FormulaState state;
  FormulaResult._(JsonObject j)
    : regionId = _uint(j['region_id']),
      state = FormulaState.fromJson(_map(j['state']));
}

class ReadingOrder {
  final List<int> regionIds;
  final String profile;
  ReadingOrder._(JsonObject j)
    : regionIds = List.unmodifiable(_list(j['region_ids']).map(_uint)),
      profile = _text(j['profile']);
}

class PageAnalysis {
  final PageDescriptor page;
  final PageProvenance provenance;
  final FormulaScope formulaScope;
  final List<LayoutRegion> regions;
  final List<FormulaResult> formulas;
  final ReadingOrder? readingOrder;
  final List<Diagnostic> diagnostics;
  PageAnalysis.fromJson(JsonObject j)
    : page = PageDescriptor.fromJson(_map(j['page'])),
      provenance = PageProvenance._(_map(j['provenance'])),
      formulaScope = _enum(FormulaScope.values, j['formula_scope']),
      regions = List.unmodifiable(
        _list(j['regions']).map((v) => LayoutRegion._(_map(v))),
      ),
      formulas = List.unmodifiable(
        _list(j['formulas']).map((v) => FormulaResult._(_map(v))),
      ),
      readingOrder = j['reading_order'] == null
          ? null
          : ReadingOrder._(_map(j['reading_order'])),
      diagnostics = _diagnostics(j['diagnostics']) {
    final ids = regions.map((r) => r.id).toSet(),
        expected = regions
            .where((r) => r.category == RegionCategory.formula)
            .map((r) => r.id)
            .toSet();
    if (ids.length != regions.length ||
        formulas.map((f) => f.regionId).toSet().length != formulas.length ||
        formulas.length != expected.length ||
        formulas.any(
          (f) =>
              !expected.contains(f.regionId) ||
              (formulaScope == FormulaScope.none) !=
                  (f.state is FormulaNotRequested),
        )) {
      throw const FormatException('Inconsistent region/formula identities');
    }
    for (final result in formulas) {
      if (result.state case FormulaFinishedState(
        outcome: FormulaRecognized(:final formula),
      )) {
        if (formula.displayKind !=
            regions.firstWhere((r) => r.id == result.regionId).displayKind) {
          throw const FormatException('Recognition changed display context');
        }
      }
    }
    final order = readingOrder;
    if (order != null &&
        (order.regionIds.length != ids.length ||
            order.regionIds.toSet().length != ids.length ||
            !ids.containsAll(order.regionIds))) {
      throw const FormatException('Reading order is not a region permutation');
    }
  }
}

enum CompletionStatus { completed, partial, cancelled, failed }

enum JobPhase { queued, running, finishing, finished }

class AnalysisCounts {
  final int pagesTotal,
      pagesFinished,
      pagesFailed,
      formulasDetected,
      formulasRecognized,
      formulasFailed,
      formulasTruncated,
      formulasPending,
      formulasNotRequested;
  AnalysisCounts._(JsonObject j)
    : pagesTotal = _uint(j['pages_total']),
      pagesFinished = _uint(j['pages_finished']),
      pagesFailed = _uint(j['pages_failed']),
      formulasDetected = _uint(j['formulas_detected']),
      formulasRecognized = _uint(j['formulas_recognized']),
      formulasFailed = _uint(j['formulas_failed']),
      formulasTruncated = _uint(j['formulas_truncated']),
      formulasPending = _uint(j['formulas_pending']),
      formulasNotRequested = _uint(j['formulas_not_requested']) {
    if (pagesFinished + pagesFailed > pagesTotal ||
        formulasRecognized +
                formulasFailed +
                formulasTruncated +
                formulasPending +
                formulasNotRequested !=
            formulasDetected) {
      throw const FormatException('Invalid analysis counts');
    }
  }
}

class AnalysisSummary {
  final CompletionStatus status;
  final AnalysisCounts counts;
  final List<Diagnostic> diagnostics;
  AnalysisSummary._(JsonObject j)
    : status = _enum(CompletionStatus.values, j['status']),
      counts = AnalysisCounts._(_map(j['counts'])),
      diagnostics = _diagnostics(j['diagnostics']) {
    final failures =
        counts.pagesFailed > 0 ||
        counts.formulasFailed > 0 ||
        counts.formulasTruncated > 0;
    if ((status == CompletionStatus.completed ||
            status == CompletionStatus.partial) &&
        (counts.pagesFinished + counts.pagesFailed != counts.pagesTotal ||
            counts.formulasPending != 0)) {
      throw const FormatException('Finished summary contains unfinished work');
    }
    if ((status == CompletionStatus.completed && failures) ||
        (status == CompletionStatus.partial && !failures)) {
      throw const FormatException('Summary status contradicts failures');
    }
  }
}

class DeliveryCounts {
  final int updatesAcknowledged, pagesFinished, formulasFinished;
  final int? lastSequence;
  final bool documentFinished;
  DeliveryCounts._(JsonObject j)
    : updatesAcknowledged = _uint(j['updates_acknowledged']),
      pagesFinished = _uint(j['pages_finished']),
      formulasFinished = _uint(j['formulas_finished']),
      lastSequence = j['last_sequence'] == null
          ? null
          : _uint(j['last_sequence']),
      documentFinished = j['document_finished'] as bool;
}

class AnalysisProgress {
  final JobPhase phase;
  final bool cancellationRequested;
  final AnalysisCounts processed;
  final DeliveryCounts delivered;
  final int inputBytes,
      pendingResultBytes,
      pendingUpdates,
      peakInputBytes,
      peakResultBytes,
      peakPendingUpdates;
  AnalysisProgress._(JsonObject j)
    : phase = _enum(JobPhase.values, j['phase']),
      cancellationRequested = j['cancellation_requested'] as bool,
      processed = AnalysisCounts._(_map(j['processed'])),
      delivered = DeliveryCounts._(_map(j['delivered'])),
      inputBytes = _uint(j['input_bytes']),
      pendingResultBytes = _uint(j['pending_result_bytes']),
      pendingUpdates = _uint(j['pending_updates']),
      peakInputBytes = _uint(j['peak_input_bytes']),
      peakResultBytes = _uint(j['peak_result_bytes']),
      peakPendingUpdates = _uint(j['peak_pending_updates']);
}

class AnalysisOutcome {
  final CompletionStatus status;
  final AnalysisSummary summary;
  final DeliveryCounts delivered;
  final PodocoException? error;
  final AnalysisProgress progress;
  AnalysisOutcome.fromJson(JsonObject j)
    : status = _enum(CompletionStatus.values, j['status']),
      summary = AnalysisSummary._(_map(j['summary'])),
      delivered = DeliveryCounts._(_map(j['delivered'])),
      error = j['error'] == null
          ? null
          : PodocoException.fromJson(_map(j['error'])),
      progress = AnalysisProgress._(_map(j['progress']));
}

sealed class AnalysisUpdate {
  final String analysisId;
  final DocumentRef document;
  final int sequence;
  final JsonObject _json;
  AnalysisUpdate._(JsonObject j)
    : analysisId = _text(j['analysis_id']),
      document = DocumentRef.fromJson(_map(j['document'])),
      sequence = _uint(j['sequence']),
      _json = _freeze(j) as JsonObject;

  /// Owned deeply immutable schema-v0 envelope, suitable for persistence.
  JsonObject toJson() => _json;
  factory AnalysisUpdate.fromJson(JsonObject j) {
    _schema(j);
    final p = _map(j['payload']);
    final update = switch (p['type']) {
      'page_layout_ready' => PageLayoutReady._(
        j,
        PageAnalysis.fromJson(_map(p['page'])),
      ),
      'page_finished' => PageFinished._(
        j,
        PageAnalysis.fromJson(_map(p['page'])),
      ),
      'formula_finished' => FormulaFinished._(
        j,
        PageKey.fromJson(_map(p['page_key'])),
        _uint(p['region_id']),
        FormulaOutcome.fromJson(_map(p['outcome'])),
      ),
      'page_failed' => PageFailed._(
        j,
        PageKey.fromJson(_map(p['page_key'])),
        PodocoException.fromJson(_map(p['error'])),
      ),
      'document_finished' => DocumentFinished._(
        j,
        AnalysisSummary._(_map(p['summary'])),
      ),
      _ => throw const FormatException('Unknown analysis update'),
    };
    final key = switch (update) {
      PageLayoutReady(:final page) => page.page.key,
      PageFinished(:final page) => page.page.key,
      FormulaFinished(:final pageKey) => pageKey,
      PageFailed(:final pageKey) => pageKey,
      _ => null,
    };
    if (key != null && key.document != update.document) {
      throw const FormatException('Update document mismatch');
    }
    if (update is PageFinished &&
        update.page.formulas.any((f) => f.state is FormulaPending)) {
      throw const FormatException('Final page has pending formulas');
    }
    if (update is PageLayoutReady &&
        update.page.formulas.any((f) => f.state is FormulaFinishedState)) {
      throw const FormatException(
        'Initial layout contains finished recognition',
      );
    }
    return update;
  }
}

final class PageLayoutReady extends AnalysisUpdate {
  final PageAnalysis page;
  PageLayoutReady._(super.j, this.page) : super._();
}

final class PageFinished extends AnalysisUpdate {
  final PageAnalysis page;
  PageFinished._(super.j, this.page) : super._();
}

final class FormulaFinished extends AnalysisUpdate {
  final PageKey pageKey;
  final int regionId;
  final FormulaOutcome outcome;
  FormulaFinished._(super.j, this.pageKey, this.regionId, this.outcome)
    : super._();
}

final class PageFailed extends AnalysisUpdate {
  final PageKey pageKey;
  final PodocoException error;
  PageFailed._(super.j, this.pageKey, this.error) : super._();
}

final class DocumentFinished extends AnalysisUpdate {
  final AnalysisSummary summary;
  DocumentFinished._(super.j, this.summary) : super._();
}
