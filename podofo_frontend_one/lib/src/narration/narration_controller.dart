import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'narrator.dart';
import 'source_map.dart';
import 'narration_sequence.dart';

class NarrationSource {
  const NarrationSource({
    required this.documentId,
    required this.title,
    required this.text,
    this.passage,
    this.sequence,
  });
  final Object documentId;
  final String title, text;
  final NarrationPassage? passage;
  final NarrationSequence? sequence;

  NarrationSource fromOffset(int offset) {
    final mapped = passage?.sliceFrom(offset);
    return NarrationSource(
      documentId: documentId,
      title: title,
      text: mapped?.text ?? text.substring(offset),
      passage: mapped,
      sequence: sequence,
    );
  }
}

/// Owns document intent and SDK handles; native states are authoritative for audio.
class NarrationController extends ChangeNotifier {
  NarrationController({
    required this.open,
    this.unavailableReason,
    this.onPosition,
  });

  final NarratorFactory open;
  final String? unavailableReason;
  final void Function(NarrationSource source, SourceAnchor anchor)? onPosition;
  String? _savedAnchor;
  NarratorSession? _session;
  Future<void>? _opening, _closing;
  NarrationPlayback? _playback;
  StreamSubscription<NarrationSnapshot>? _subscription;
  final Set<Future<void>> _retiring = {};
  int _generation = 0;
  Object? _pendingDocumentId;
  bool _closed = false, _pauseWhenReady = false;
  NarrationSource? source;
  NarrationSnapshot? snapshot;
  List<NarrationVoice> voices = const [];
  NarrationSettings settings = const NarrationSettings();
  String? error;
  String preparation = '';
  bool preparing = false;
  bool followText = true;
  List<NarrationSentence> sentences = const [];
  bool _readingPlan = false;
  SourceAnchor? get currentAnchor =>
      source?.passage?.anchorAt(snapshot?.start ?? 0);

  bool get available => unavailableReason == null;
  bool get active => preparing || (_playback != null && !terminal);
  bool get paused =>
      _pauseWhenReady || snapshot?.phase == NarrationPhase.paused;
  bool get terminal => switch (snapshot?.phase) {
    NarrationPhase.completed ||
    NarrationPhase.stopped ||
    NarrationPhase.failed => true,
    _ => false,
  };
  String get status =>
      error ??
      (preparing
          ? preparation
          : switch (snapshot?.phase) {
              NarrationPhase.playing => 'Reading aloud',
              NarrationPhase.paused => 'Paused',
              NarrationPhase.completed => 'Finished reading',
              NarrationPhase.stopped => 'Stopped',
              NarrationPhase.failed => 'Speech interrupted',
              _ =>
                snapshot?.seeking == true
                    ? 'Preparing passage…'
                    : 'Preparing speech…',
            });

  void _notify() {
    if (!_closed) notifyListeners();
  }

  bool _current(int generation) => !_closed && generation == _generation;

  Future<void> _load() => _session != null
      ? Future.value()
      : _opening ??= _loadSession().whenComplete(() => _opening = null);

  Future<void> _loadSession() async {
    final session = await open((message) {
      if (preparing) preparation = message;
      _notify();
    });
    try {
      final catalog = await session.voices();
      if (_closed) throw StateError('Narration closed while loading');
      if (catalog.isEmpty) throw StateError('No speech voices are available.');
      voices = List.unmodifiable(catalog);
      if (settings.voice.isNotEmpty &&
          !voices.any((v) => v.id == settings.voice)) {
        settings = NarrationSettings(
          language: settings.language,
          speed: settings.speed,
        );
      }
      _session = session;
    } catch (_) {
      await session.dispose();
      rethrow;
    }
  }

  /// Resolving the selection is part of the cancellable app operation. Stop or
  /// another Read invalidates even a late PDF extraction or model-load result.
  Future<void> read(
    Object documentId,
    Future<NarrationSource> Function() resolve, {
    bool keepSequence = false,
  }) async {
    if (_closed) return;
    if (!available) {
      error = unavailableReason;
      _notify();
      return;
    }
    final generation = ++_generation;
    _remember();
    if (!keepSequence) {
      source?.sequence?.close();
    } else {
      source?.sequence?.cancelPending();
    }
    _pendingDocumentId = documentId;
    _retireCurrent();
    preparing = true;
    _pauseWhenReady = false;
    error = null;
    snapshot = null;
    sentences = const [];
    source = null;
    preparation = 'Reading selected text…';
    _notify();
    try {
      final next = await resolve();
      if (!_current(generation)) {
        if (!identical(next.sequence, source?.sequence)) next.sequence?.close();
        return;
      }
      await _start(next, generation);
    } catch (failure) {
      if (_current(generation)) {
        preparing = false;
        _pendingDocumentId = null;
        error = failure.toString();
        _notify();
      }
    }
  }

  Future<void> _start(NarrationSource next, int generation) async {
    if (next.text.trim().isEmpty) {
      throw StateError('Select readable text first.');
    }
    if (utf8.encode(next.text).length > 64 * 1024) {
      throw StateError('This selection is too long. Select a shorter passage.');
    }
    source = next;
    preparation = 'Loading voices…';
    _notify();
    await _load();
    await _joinRetiring();
    if (!_current(generation)) return;
    final playback = _session!.speak(
      next.text,
      settings,
      paused: _pauseWhenReady,
    );
    preparing = false;
    _pendingDocumentId = null;
    _observe(playback, generation);
    final sequence = next.sequence;
    if (sequence != null) unawaited(_prepareNext(sequence));
  }

  Future<void> _prepareNext(NarrationSequence sequence) async {
    try {
      await sequence.prepareNext();
    } catch (_) {
      // Preparation is speculative. Report an extraction/review error only if
      // playback reaches that page; stopping or replacing it stays quiet.
    }
  }

  void _remember() {
    final value = source, anchor = currentAnchor;
    if (value == null || anchor == null || onPosition == null) return;
    final key =
        '${identityHashCode(value.documentId)}:${anchor.page}:${anchor.offset}:${anchor.textHash}';
    if (key == _savedAnchor) return;
    try {
      onPosition!(value, anchor);
      _savedAnchor = key;
    } catch (failure) {
      error = 'Could not save your reading position: $failure';
    }
  }

  Future<void> movePassage(int direction) async {
    final previous = source, sequence = source?.sequence;
    if (previous == null || sequence == null || _closed || preparing) return;
    final generation = ++_generation;
    _remember();
    final keepPaused = paused;
    _pauseWhenReady = keepPaused;
    _retireCurrent();
    preparing = true;
    preparation = 'Preparing the next passage…';
    error = null;
    _notify();
    try {
      final next = await sequence.move(direction);
      if (!_current(generation)) return;
      if (next == null) {
        preparing = false;
        snapshot =
            snapshot?.withPhase(NarrationPhase.completed) ??
            const NarrationSnapshot(phase: NarrationPhase.completed);
        _notify();
        return;
      }
      snapshot = null;
      sentences = const [];
      await _start(
        NarrationSource(
          documentId: previous.documentId,
          title: previous.title,
          text: next.text,
          passage: next,
          sequence: sequence,
        ),
        generation,
      );
    } catch (failure) {
      if (_current(generation)) {
        preparing = false;
        error = failure.toString();
        snapshot =
            snapshot?.withPhase(NarrationPhase.failed) ??
            const NarrationSnapshot(phase: NarrationPhase.failed);
        _notify();
      }
    }
  }

  void _observe(NarrationPlayback playback, int generation) {
    _playback = playback;
    _subscription = playback.states.listen(
      (value) {
        if (!_current(generation) || !identical(_playback, playback)) return;
        snapshot = value;
        if (value.start != null) _remember();
        if (sentences.isEmpty && !_readingPlan) {
          unawaited(_updatePlan(playback, generation));
        }
        if (value.phase == NarrationPhase.playing) _pauseWhenReady = false;
        _notify();
      },
      onError: (Object failure) {
        if (_current(generation)) {
          error = failure.toString();
          _notify();
        }
      },
    );
    unawaited(_completion(playback, generation));
    _notify();
  }

  Future<void> _updatePlan(NarrationPlayback playback, int generation) async {
    _readingPlan = true;
    try {
      final plan = await playback.sentences();
      if (_current(generation) &&
          identical(_playback, playback) &&
          plan != null) {
        sentences = List.unmodifiable(plan);
        _notify();
      }
    } catch (failure) {
      if (_current(generation) && identical(_playback, playback)) {
        error = 'Could not read sentence positions: $failure';
        _notify();
      }
    } finally {
      _readingPlan = false;
    }
  }

  void setFollowText(bool value) {
    followText = value;
    _notify();
  }

  void navigate({required bool forward}) {
    final playback = _playback;
    if (playback == null) {
      unawaited(movePassage(forward ? 1 : -1));
      return;
    }
    if (sentences.isEmpty) return;
    try {
      final result = playback.navigate(forward: forward);
      if (result.boundary && source?.sequence != null) {
        unawaited(movePassage(forward ? 1 : -1));
      } else {
        _acceptNavigation(result);
      }
    } catch (failure) {
      error = failure.toString();
      _notify();
    }
  }

  void _acceptNavigation(NarrationNavigation navigation) {
    final replacement = navigation.replacement;
    if (replacement != null) {
      final generation = ++_generation;
      _retireCurrent();
      _pauseWhenReady = false;
      _observe(replacement, generation);
    }
  }

  void seek(int frame) {
    final total = snapshot?.durationFrames ?? snapshot?.estimatedFrames;
    if (total == null || total <= 0) return;
    try {
      _playback?.seek(frame.clamp(0, total - 1));
    } catch (failure) {
      error = failure.toString();
      _notify();
    }
  }

  /// Synthesis changes restart at the native sentence's source boundary.
  Future<void> configure(NarrationSettings next) async {
    if (!next.speed.isFinite || next.speed < 0.5 || next.speed > 2) {
      throw ArgumentError('Speaking speed must be between 0.5 and 2.0.');
    }
    if (next.voice == settings.voice &&
        next.language == settings.language &&
        next.speed == settings.speed) {
      return;
    }
    settings = next;
    final previous = source;
    if (previous != null && active) {
      final keepPaused = paused;
      final replacement = previous.fromOffset(snapshot?.start ?? 0);
      final work = read(
        previous.documentId,
        () async => replacement,
        keepSequence: true,
      );
      _pauseWhenReady = keepPaused;
      await work;
    } else {
      _notify();
    }
  }

  Future<void> _completion(NarrationPlayback playback, int generation) async {
    try {
      final result = await playback.done;
      if (!_current(generation) || !identical(_playback, playback)) return;
      final phase = result == NarrationOutcome.completed
          ? NarrationPhase.completed
          : NarrationPhase.stopped;
      snapshot = snapshot?.withPhase(phase) ?? NarrationSnapshot(phase: phase);
      if (result == NarrationOutcome.completed && source?.sequence != null) {
        await movePassage(1);
        return;
      }
      _notify();
    } catch (failure) {
      if (_current(generation) && identical(_playback, playback)) {
        error = failure.toString();
        snapshot = const NarrationSnapshot(phase: NarrationPhase.failed);
        _notify();
      }
    }
  }

  void togglePause() {
    if (_closed) return;
    if (terminal && !preparing && source != null) {
      final saved = source!;
      unawaited(read(saved.documentId, () async => saved, keepSequence: true));
      return;
    }
    _pauseWhenReady = !paused;
    try {
      if (_pauseWhenReady) {
        _playback?.pause();
      } else {
        _playback?.resume();
      }
      _notify();
    } catch (failure) {
      error = failure.toString();
      _notify();
    }
  }

  void _retireCurrent() {
    final playback = _playback;
    final subscription = _subscription;
    _playback = null;
    _subscription = null;
    if (playback == null) return;
    try {
      playback.cancel();
    } catch (failure) {
      if (!_closed) error = 'Could not stop speech: $failure';
    }
    late final Future<void> work;
    work =
        () async {
              try {
                await subscription?.cancel();
              } finally {
                await playback.dispose();
              }
            }()
            .catchError((Object failure) {
              // Cleanup failure is observable, but cannot resurrect a retired request.
              if (!_closed) error = 'Could not release speech: $failure';
            })
            .whenComplete(() => _retiring.remove(work));
    _retiring.add(work);
  }

  Future<void> _joinRetiring() async {
    await Future.wait(_retiring.toList());
  }

  Future<void> stop() async {
    _remember();
    source?.sequence?.cancelPending();
    ++_generation;
    preparing = false;
    _pendingDocumentId = null;
    _pauseWhenReady = false;
    _retireCurrent();
    snapshot = const NarrationSnapshot(phase: NarrationPhase.stopped);
    _notify();
    await _joinRetiring();
  }

  Future<void> closeDocument(Object documentId) async {
    if (!identical(source?.documentId, documentId) &&
        !identical(_pendingDocumentId, documentId)) {
      return;
    }
    final sequence = source?.sequence;
    final generation = _generation + 1;
    await stop();
    sequence?.close();
    if (_generation != generation) return;
    source = null;
    snapshot = null;
    _notify();
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    await stop();
    source?.sequence?.close();
    try {
      await _opening;
    } catch (_) {
      // _loadSession has already released a late or failed session.
    }
    await _session?.dispose();
    _session = null;
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }
}
