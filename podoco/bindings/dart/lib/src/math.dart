part of 'analysis.dart';

/// Whether the native library contains the independent optional math module.
bool get mathAvailable {
  _checkNative();
  return native.podoco_features() & native.PODOCO_FEATURE_MATH != 0;
}

void _requireMath() {
  if (!mathAvailable) {
    throw const PodocoException(
      'unsupported_capability',
      'This native library does not provide math conversion.',
    );
  }
}

/// Exact offline rule identity. Keep these files immutable while in use.
class MathRules {
  final String directory, id, profile, manifestSha256;
  MathRules._(this.directory, JsonObject j)
    : id = _text(j['id']),
      profile = _text(j['profile']),
      manifestSha256 = _sha(j['manifest_sha256']);

  static Future<MathRules> verify(String directory) async {
    _requireMath(); // Check before resolving additive ABI-2 symbols.
    final result = await Isolate.run(
      () => using(
        (arena) => _takeJson(
          _newHandle(
            (out, error) => native.podoco_math_rules_verify(
              _bytes(arena, utf8.encode(directory)),
              out,
              error,
            ),
          ),
        ),
      ),
    );
    _schema(result);
    return MathRules._(directory, result);
  }
}

/// Logical input/output/complexity limits, excluding rule tables and dependency
/// internals. The queue excludes one active conversion.
class MathLimits {
  final int queuedRequests, inputBytes, outputBytes, nodes, depth;
  MathLimits({
    this.queuedRequests = 4,
    this.inputBytes = 64 * 1024,
    this.outputBytes = 256 * 1024,
    this.nodes = 8192,
    this.depth = 64,
  }) {
    for (final (name, value, max) in [
      ('queuedRequests', queuedRequests, 32),
      ('inputBytes', inputBytes, 65536),
      ('outputBytes', outputBytes, 1048576),
      ('nodes', nodes, 8192),
      ('depth', depth, 64),
    ]) {
      RangeError.checkValueInInterval(value, 1, max, name);
    }
  }
  factory MathLimits.fromJson(JsonObject j) => MathLimits(
    queuedRequests: _uint(j['queued_requests']),
    inputBytes: _uint(j['input_bytes']),
    outputBytes: _uint(j['output_bytes']),
    nodes: _uint(j['nodes']),
    depth: _uint(j['depth']),
  );
  JsonObject toJson() => {
    'queued_requests': queuedRequests,
    'input_bytes': inputBytes,
    'output_bytes': outputBytes,
    'nodes': nodes,
    'depth': depth,
  };
}

enum MathFormat { latex, mathml }

/// Original expression and explicit layout/caller display context.
class MathInput {
  final MathFormat format;
  final String text;
  final FormulaDisplayKind displayKind;
  const MathInput.latex(this.text, {required this.displayKind})
    : format = MathFormat.latex;
  const MathInput.mathml(this.text, {required this.displayKind})
    : format = MathFormat.mathml;
  JsonObject toJson() => {
    'format': format.name,
    'text': text,
    'display_kind': displayKind.name,
  };
}

enum MathVerbosity { terse, medium, verbose }

/// Complete explicit preference snapshot. Numeric separators are independent
/// of the spoken language; no locale or style fallback is performed.
class MathSpeechOptions {
  final String language, speechStyle, decimalSeparators, blockSeparators;
  final MathVerbosity verbosity;
  const MathSpeechOptions({
    required this.language,
    required this.speechStyle,
    this.verbosity = MathVerbosity.medium,
    this.decimalSeparators = '.',
    this.blockSeparators = ', \u00a0\u202f',
  });
  factory MathSpeechOptions.fromJson(JsonObject j) => MathSpeechOptions(
    language: _text(j['language']),
    speechStyle: _text(j['speech_style']),
    verbosity: switch (j['verbosity']) {
      'Terse' => MathVerbosity.terse,
      'Medium' => MathVerbosity.medium,
      'Verbose' => MathVerbosity.verbose,
      _ => throw const FormatException('Unsupported math verbosity'),
    },
    decimalSeparators: j['decimal_separators'] as String,
    blockSeparators: j['block_separators'] as String,
  );
  JsonObject toJson() => {
    'language': language,
    'speech_style': speechStyle,
    'verbosity': switch (verbosity) {
      MathVerbosity.terse => 'Terse',
      MathVerbosity.medium => 'Medium',
      MathVerbosity.verbose => 'Verbose',
    },
    'decimal_separators': decimalSeparators,
    'block_separators': blockSeparators,
  };
}

class MathLanguage {
  final String language;
  final List<String> speechStyles;
  MathLanguage._(JsonObject j)
    : language = _text(j['language']),
      speechStyles = List.unmodifiable(_list(j['speech_styles']).map(_text));
}

class MathProvenance {
  final String sdkVersion, profile, converter, mathcat, rulesManifestSha256;
  MathProvenance._(JsonObject j)
    : sdkVersion = _text(j['sdk_version']),
      profile = _text(j['profile']),
      converter = _text(j['converter']),
      mathcat = _text(j['mathcat']),
      rulesManifestSha256 = _sha(j['rules_manifest_sha256']);
}

/// Derived output; conversion never replaces or mutates the original LaTeX.
class MathConversion {
  final String mathml;
  final FormulaDisplayKind displayKind;
  final List<Diagnostic> diagnostics;
  final MathProvenance provenance;
  final JsonObject _json;
  MathConversion._(JsonObject j)
    : mathml = _text(j['mathml']),
      displayKind = _enum(FormulaDisplayKind.values, j['display_kind']),
      diagnostics = _diagnostics(j['diagnostics']),
      provenance = MathProvenance._(_map(j['provenance'])),
      _json = _freeze(j) as JsonObject;
  JsonObject toJson() => _json;
}

/// Plain speech text for an independently configured TTS system; no audio plays.
class MathSpeech extends MathConversion {
  final String text;
  final MathSpeechOptions options;
  MathSpeech._(super.j)
    : text = _text(j['text']),
      options = MathSpeechOptions.fromJson(_map(j['options'])),
      super._();
}

int _openMath(JsonObject config) => using(
  (arena) => _newHandle(
    (out, error) =>
        native.podoco_math_open(_jsonBytes(arena, config), out, error),
  ),
);
JsonObject _convertMath(int handle, JsonObject config) => using(
  (arena) => _takeJson(
    _newHandle(
      (out, error) => native.podoco_math_convert(
        handle,
        _jsonBytes(arena, config),
        out,
        error,
      ),
    ),
  ),
);

// Separate scopes prevent closure-context sharing from capturing the owner's
// unsendable pending Futures during concurrent calls and disposal.
Future<JsonObject> _convertMathAsync(int handle, JsonObject config) =>
    Isolate.run(() => _convertMath(handle, config));
Future<void> _closeMathAsync(int handle) => Isolate.run(
  () => _control((error) => native.podoco_math_close(handle, error)),
);

/// Independent native worker. Calls run off the UI isolate; admission is bounded
/// before spawning bridge isolates as well as inside the native worker.
class MathProcessor {
  int _handle;
  final MathLimits limits;
  final String rulesId, profile, rulesManifestSha256;
  final List<MathLanguage> languages;
  final Set<Future<void>> _pending = {};
  Future<void>? _closing;
  MathProcessor._(this._handle, JsonObject info)
    : limits = MathLimits.fromJson(_map(info['limits'])),
      rulesId = _text(info['rules_id']),
      profile = _text(info['profile']),
      rulesManifestSha256 = _sha(info['rules_manifest_sha256']),
      languages = List.unmodifiable(
        _list(info['languages']).map((v) => MathLanguage._(_map(v))),
      ) {
    _handleFinalizer.attach(this, _handle, detach: this);
  }
  static Future<MathProcessor> open(
    MathRules rules, {
    MathLimits? limits,
  }) async {
    _requireMath();
    final config = {
      'schema_version': 0,
      'rules_directory': rules.directory,
      'limits': (limits ?? MathLimits()).toJson(),
    };
    final handle = await Isolate.run(() => _openMath(config));
    try {
      final info = _takeJson(
        _newHandle((out, error) => native.podoco_math_info(handle, out, error)),
      );
      _schema(info);
      return MathProcessor._(handle, info);
    } catch (_) {
      await _releaseAsync(handle);
      rethrow;
    }
  }

  Future<MathConversion> toMathml(MathInput input) async =>
      MathConversion._(await _convert(input, null));
  Future<MathSpeech> toSpeech(
    MathInput input,
    MathSpeechOptions options,
  ) async => MathSpeech._(await _convert(input, options));

  Future<JsonObject> _convert(MathInput input, MathSpeechOptions? options) {
    if (_closing != null || _handle == 0) {
      throw StateError('Math processor is closed');
    }
    if (_pending.length >= limits.queuedRequests + 1) {
      throw const PodocoException(
        'limit_exceeded',
        'Math request queue is full',
      );
    }
    if (input.text.length > limits.inputBytes ||
        utf8.encode(input.text).length > limits.inputBytes) {
      throw const PodocoException(
        'limit_exceeded',
        'Math input exceeds byte limit',
      );
    }
    // Copy only immutable metadata into the bridge isolate, never this owner.
    final handle = _handle;
    final config = {
      'schema_version': 0,
      'input': input.toJson(),
      if (options != null) 'speech_options': options.toJson(),
    };
    final result = _convertMathAsync(handle, config).then((j) {
      _schema(j);
      if (j['kind'] != (options == null ? 'mathml' : 'speech')) {
        throw const FormatException('Unexpected math result kind');
      }
      return _map(j['value']);
    });
    // Cleanup observers never surface a second unhandled conversion error.
    late final Future<void> settled;
    settled = result
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() => _pending.remove(settled));
    _pending.add(settled);
    return result;
  }

  /// Cancel native queued work immediately, drain active calls, then release.
  /// Idempotent. New requests are rejected once disposal starts.
  Future<void> dispose() => _closing ??= _dispose();
  Future<void> _dispose() async {
    final handle = _handle;
    try {
      await _closeMathAsync(handle);
    } finally {
      await Future.wait(_pending.toList());
      _handle = 0;
      _handleFinalizer.detach(this);
      await _releaseAsync(handle);
    }
  }
}
