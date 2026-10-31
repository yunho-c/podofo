part of 'analysis.dart';

void _requireFormulaJobs() {
  _checkNative();
  if (native.podoco_features() & native.PODOCO_FEATURE_FORMULA_JOBS == 0) {
    throw const PodocoException(
      'unsupported_capability',
      'This native library does not provide queued explicit formula crops.',
    );
  }
}

/// Caller-supplied identity and geometry, without a layout detection.
class FormulaCrop {
  final PageDescriptor page;
  final int regionId;
  final PageRect bounds;
  final FormulaDisplayKind displayKind;
  FormulaCrop({
    required this.page,
    required this.regionId,
    required this.bounds,
    required this.displayKind,
  }) {
    if (regionId < 0 || regionId > 0xffffffff) {
      throw ArgumentError('regionId must fit uint32');
    }
    if (bounds.left < 0 ||
        bounds.top < 0 ||
        bounds.right > page.space.width ||
        bounds.bottom > page.space.height) {
      throw ArgumentError('Formula bounds must lie within the owning page');
    }
  }
  factory FormulaCrop.fromJson(JsonObject j) => FormulaCrop(
    page: PageDescriptor.fromJson(_map(j['page'])),
    regionId: _uint(j['region_id']),
    bounds: PageRect.fromJson(j['bounds']),
    displayKind: _enum(FormulaDisplayKind.values, j['display_kind']),
  );
  JsonObject toJson() => {
    'page': page.toJson(),
    'region_id': regionId,
    'bounds': [bounds.left, bounds.top, bounds.right, bounds.bottom],
    'display_kind': displayKind.name,
  };
  @override
  bool operator ==(Object other) =>
      other is FormulaCrop &&
      page.key == other.page.key &&
      page.space.width == other.page.space.width &&
      page.space.height == other.page.space.height &&
      regionId == other.regionId &&
      bounds.left == other.bounds.left &&
      bounds.top == other.bounds.top &&
      bounds.right == other.bounds.right &&
      bounds.bottom == other.bounds.bottom &&
      displayKind == other.displayKind;
  @override
  int get hashCode => Object.hash(
    page.key,
    page.space.width,
    page.space.height,
    regionId,
    bounds.left,
    bounds.top,
    bounds.right,
    bounds.bottom,
    displayKind,
  );
}

/// Lazy crop request under the same input reservation as a document page.
class FormulaRequest {
  final FormulaCrop crop;
  final RasterRequirements requirements;
  final int byteBudget;
  final CancellationToken cancellation;
  FormulaRequest._(this.crop, PageRequest request)
    : requirements = request.requirements,
      byteBudget = request.byteBudget,
      cancellation = request.cancellation;
}

class FormulaJobProgress {
  final JobPhase phase;
  final bool cancellationRequested;
  final int inputBytes, peakInputBytes, peakResultBytes;
  FormulaJobProgress._(JsonObject j)
    : phase = _enum(JobPhase.values, j['phase']),
      cancellationRequested = j['cancellation_requested'] as bool,
      inputBytes = _uint(j['input_bytes']),
      peakInputBytes = _uint(j['peak_input_bytes']),
      peakResultBytes = _uint(j['peak_result_bytes']) {
    if (inputBytes > peakInputBytes ||
        (phase == JobPhase.finished && inputBytes != 0)) {
      throw const FormatException('Invalid formula resource progress');
    }
  }
}

/// Authoritative result after the loader, native readers and release callbacks drain.
class FormulaJobOutcome {
  final JsonObject _json;
  final String analysisId;
  final FormulaCrop crop;
  final CompletionStatus status;
  final FormulaOutcome? outcome;
  final PodocoException? error;
  final FormulaJobProgress progress;
  FormulaJobOutcome.fromJson(JsonObject j)
    : _json = _freeze(j) as JsonObject,
      analysisId = _text(j['analysis_id']),
      crop = FormulaCrop.fromJson(_map(j['crop'])),
      status = _enum(CompletionStatus.values, j['status']),
      outcome = j['outcome'] == null
          ? null
          : FormulaOutcome.fromJson(_map(j['outcome'])),
      error = j['error'] == null
          ? null
          : PodocoException.fromJson(_map(j['error'])),
      progress = FormulaJobProgress._(_map(j['progress'])) {
    if (progress.phase != JobPhase.finished ||
        (status == CompletionStatus.failed ? error == null : error != null) ||
        switch (status) {
          CompletionStatus.completed => outcome is! FormulaRecognized,
          CompletionStatus.partial =>
            outcome is! FormulaFailed && outcome is! FormulaTruncated,
          CompletionStatus.cancelled => outcome != null,
          CompletionStatus.failed => false,
        }) {
      throw const FormatException('Inconsistent formula completion');
    }
    if (outcome case FormulaRecognized(:final formula)) {
      if (formula.displayKind != crop.displayKind) {
        throw const FormatException(
          'Recognition changed the supplied formula context',
        );
      }
    }
  }

  /// Deeply immutable owned result, suitable for caller-managed persistence.
  JsonObject toJson() => _json;
}

/// Eager formula work sharing the analyzer's FIFO and native models. The binding
/// automatically acknowledges the release barrier; there are no fake layout events.
class FormulaJob extends _NativeJob<FormulaJobOutcome, FormulaJobProgress> {
  FormulaJob._(Analyzer analyzer, PageSource source, FormulaCrop crop)
    : super._(
        analyzer,
        source,
        crop.page.key.document,
        null,
        formula: true,
        decodeProgress: FormulaJobProgress._,
        decodeOutcome: (json) {
          final outcome = FormulaJobOutcome.fromJson(json);
          if (outcome.crop != crop) {
            throw const FormatException(
              'Formula result belongs to a different crop',
            );
          }
          return outcome;
        },
        outcomeProgress: (outcome) => outcome.progress,
        outcomeStatus: (outcome) => outcome.status,
      );
}
