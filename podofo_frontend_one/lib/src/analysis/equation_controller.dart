import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:podoco/podoco.dart' as podoco;

import '../narration/narration_controller.dart';
import '../services/pdf_session.dart';
import 'analysis_controller.dart';
import 'math_speech_engine.dart';
import 'pdf_analysis_source.dart';

class EquationSelection {
  const EquationSelection(
    this.session,
    this.document,
    this.analysisId,
    this.pageIndex,
    this.region,
    this.state,
  );
  final PdfSession session;
  final podoco.DocumentRef document;
  final String analysisId;
  final int pageIndex;
  final podoco.LayoutRegion region;
  final podoco.FormulaState state;
  podoco.RecognizedFormula? get recognized => switch (state) {
    podoco.FormulaFinishedState(
      outcome: podoco.FormulaRecognized(:final formula),
    ) =>
      formula,
    _ => null,
  };
  String get identity =>
      jsonEncode([document.toJson(), analysisId, pageIndex, region.id]);
}

/// Owns equation selection/conversion intent; playback remains in the shared
/// narrator. Cached plain text is bounded and independent of the selected voice.
class EquationController extends ChangeNotifier {
  EquationController({
    required this.analysis,
    required this.narration,
    this.open = NativeMathSpeechEngine.open,
    Future<void> Function(String)? copy,
  }) : _copy = copy ?? _clipboard {
    analysis.addListener(_analysisChanged);
    narration.addListener(_narrationChanged);
    _language = narration.settings.language;
  }
  final AnalysisController analysis;
  final NarrationController narration;
  final Future<MathSpeechEngine> Function(String) open;
  final Future<void> Function(String) _copy;
  MathSpeechEngine? _math;
  Future<void>? _configuration, _closing, _listening;
  bool _disposed = false;
  int _generation = 0;
  int? _selectedId;
  String? _selectedAnalysis;
  podoco.PageKey? _selectedPage;
  Object? _owner;
  String? _requestKey;
  String _style = 'ClearSpeak', _language = 'en';
  String? rulesDirectory, error, lastSpeechText;
  List<String> diagnostics = const [];
  final _cache = <String, EquationSpeechText>{};
  int _cacheBytes = 0;
  static const _maxCacheBytes = 4 * 1024 * 1024;
  static const _maxCacheEntries = 256;
  bool get ready => _math != null;
  bool get opening => _configuration != null;
  String get speechStyle => _style;
  List<String> get availableStyles =>
      _math?.stylesFor(narration.settings.language) ?? const [];
  bool get ownsNarration =>
      _owner != null && identical(narration.requestOwner, _owner);
  bool get speaking => ownsNarration && narration.active;
  bool get converting =>
      ownsNarration && _listening != null && lastSpeechText == null;
  int get cachedBytes => _cacheBytes;

  EquationSelection? get selected {
    final snapshot = analysis.visibleSnapshot, session = analysis.session;
    if (snapshot == null ||
        session == null ||
        session.lease.isClosed ||
        snapshot.analysisId != _selectedAnalysis ||
        snapshot.page.page.key != _selectedPage ||
        snapshot.page.page.key.document != analysisDocumentRef(session)) {
      return null;
    }
    final region = snapshot.page.regions
        .where(
          (r) =>
              r.id == _selectedId &&
              r.category == podoco.RegionCategory.formula,
        )
        .firstOrNull;
    final formula = snapshot.page.formulas
        .where((f) => f.regionId == _selectedId)
        .firstOrNull;
    return region == null || formula == null
        ? null
        : EquationSelection(
            session,
            snapshot.page.page.key.document,
            snapshot.analysisId,
            snapshot.page.page.key.pageIndex,
            region,
            formula.state,
          );
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _analysisChanged() {
    if (_selectedId != null && selected == null) _clearSelection();
    _notify();
  }

  void _narrationChanged() {
    if (_selectedId != null && selected == null) _clearSelection();
    if (_language != narration.settings.language) {
      _language = narration.settings.language;
      _invalidateSpeech(); // Plain text must be regenerated in the new language.
    }
    _notify();
  }

  void _invalidateSpeech() {
    ++_generation;
    final owner = _owner;
    _owner = null;
    _requestKey = null;
    _listening = null;
    lastSpeechText = null;
    diagnostics = const [];
    if (owner != null && identical(narration.requestOwner, owner)) {
      narration.dismiss().ignore();
    }
  }

  void _clearSelection() {
    _selectedId = null;
    _selectedAnalysis = null;
    _selectedPage = null;
    _invalidateSpeech();
    error = null;
  }

  void select(int regionId) {
    if (_disposed) return;
    final snapshot = analysis.visibleSnapshot;
    if (snapshot == null ||
        !snapshot.page.regions.any(
          (r) =>
              r.id == regionId && r.category == podoco.RegionCategory.formula,
        )) {
      throw ArgumentError('Select a formula on the current analyzed page');
    }
    if (_selectedId == regionId &&
        _selectedAnalysis == snapshot.analysisId &&
        _selectedPage == snapshot.page.page.key) {
      return;
    }
    _clearSelection();
    _selectedId = regionId;
    _selectedAnalysis = snapshot.analysisId;
    _selectedPage = snapshot.page.page.key;
    _notify();
  }

  void setSpeechStyle(String value) {
    if (_style == value) return;
    _style = value;
    _invalidateSpeech();
    error = null;
    _notify();
  }

  Future<void> configureRules(String directory) {
    if (_disposed) throw StateError('Equation controller is closed');
    if (_configuration != null) return _configuration!;
    final task = _configure(directory);
    _configuration = task;
    _notify();
    return task;
  }

  Future<void> _configure(String directory) async {
    _invalidateSpeech();
    error = null;
    final previous = _math;
    _math = null;
    _cache.clear();
    _cacheBytes = 0;
    try {
      await previous?.close();
      final next = await open(directory);
      if (_disposed) {
        await next.close();
        return;
      }
      _math = next;
      rulesDirectory = directory;
    } catch (e) {
      if (!_disposed) error = e.toString();
    } finally {
      _configuration = null;
      _notify();
    }
  }

  Future<void> copyLatex() async {
    final formula = selected?.recognized;
    if (_disposed || formula == null) {
      throw StateError('Select a successfully recognized equation');
    }
    error = null;
    try {
      await _copy(formula.latex);
    } catch (e) {
      if (!_disposed) error = e.toString();
    }
    _notify();
  }

  Future<void> listen() {
    final selection = selected, math = _math;
    final formula = selection?.recognized;
    if (_disposed ||
        selection == null ||
        formula == null ||
        math == null ||
        opening) {
      throw StateError(
        'Select a recognized equation and open math rules first',
      );
    }
    final options = podoco.MathSpeechOptions(
      language: narration.settings.language,
      speechStyle: _style,
    );
    final requestKey = jsonEncode([
      selection.identity,
      formula.latex,
      options.toJson(),
      narration.settings.key,
      math.identity,
    ]);
    if (_requestKey == requestKey && ownsNarration && narration.active) {
      return _listening ?? Future.value();
    }
    _invalidateSpeech();
    final generation = _generation;
    final owner = Object();
    _owner = owner;
    _requestKey = requestKey;
    error = null;
    bool current() =>
        !_disposed &&
        generation == _generation &&
        identical(narration.requestOwner, owner) &&
        narration.active &&
        identical(math, _math) &&
        selected?.identity == selection.identity &&
        narration.settings.language == options.language;
    final work = narration.read(selection.session, () async {
      final key = sha256
          .convert(
            utf8.encode(
              jsonEncode([
                math.identity,
                formula.latex,
                formula.displayKind.name,
                options.toJson(),
              ]),
            ),
          )
          .toString();
      try {
        if (!math.stylesFor(options.language).contains(options.speechStyle)) {
          throw const podoco.PodocoException(
            'unsupported_capability',
            'Math speech does not support this narration language and style.',
          );
        }
        final speech = _cache[key] ?? await math.convert(formula, options);
        if (!current()) throw StateError('Equation selection changed');
        if (speech.text.trim().isEmpty ||
            utf8.encode(speech.text).length > 64 * 1024) {
          throw StateError(
            'Converted equation exceeds the narration text limit',
          );
        }
        _remember(key, speech);
        lastSpeechText = speech.text;
        diagnostics = speech.diagnostics;
        _notify();
        return NarrationSource(
          documentId: selection.session,
          title: 'Equation on page ${selection.pageIndex + 1}',
          text: speech.text,
        );
      } catch (e) {
        if (current()) {
          error = e.toString();
          _notify();
        }
        rethrow;
      }
    }, owner: owner);
    _listening = work;
    unawaited(
      work.whenComplete(() {
        if (identical(_listening, work)) _listening = null;
        _notify();
      }),
    );
    _notify();
    return work;
  }

  void _remember(String key, EquationSpeechText value) {
    final old = _cache.remove(key);
    if (old != null) _cacheBytes -= old.retainedBytes;
    final bytes = value.retainedBytes;
    if (bytes > _maxCacheBytes) return;
    _cache[key] = value;
    _cacheBytes += bytes;
    while (_cacheBytes > _maxCacheBytes || _cache.length > _maxCacheEntries) {
      _cacheBytes -= _cache.remove(_cache.keys.first)!.retainedBytes;
    }
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _disposed = true;
    analysis.removeListener(_analysisChanged);
    narration.removeListener(_narrationChanged);
    final owner = _owner;
    _owner = null;
    ++_generation;
    if (owner != null && identical(narration.requestOwner, owner)) {
      await narration.dismiss();
    }
    await _configuration;
    await _math?.close();
    _math = null;
    _cache.clear();
    _cacheBytes = 0;
  }

  @override
  void dispose() {
    close().ignore();
    super.dispose();
  }
}

Future<void> _clipboard(String text) =>
    Clipboard.setData(ClipboardData(text: text));
