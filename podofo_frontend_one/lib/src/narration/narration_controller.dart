import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'narrator.dart';

class NarrationSource {
  const NarrationSource({
    required this.documentId,
    required this.title,
    required this.text,
  });
  final Object documentId;
  final String title, text;
}

/// Owns document intent and SDK handles; native states are authoritative for audio.
class NarrationController extends ChangeNotifier {
  NarrationController({required this.open, this.unavailableReason});

  final NarratorFactory open;
  final String? unavailableReason;
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
    Future<NarrationSource> Function() resolve,
  ) async {
    if (_closed) return;
    if (!available) {
      error = unavailableReason;
      _notify();
      return;
    }
    final generation = ++_generation;
    _pendingDocumentId = documentId;
    _retireCurrent();
    preparing = true;
    _pauseWhenReady = false;
    error = null;
    snapshot = null;
    preparation = 'Reading selected text…';
    _notify();
    try {
      final next = await resolve();
      if (!_current(generation)) return;
      if (next.text.trim().isEmpty) {
        throw StateError('Select readable text first.');
      }
      if (utf8.encode(next.text).length > 64 * 1024) {
        throw StateError(
          'This selection is too long. Select a shorter passage.',
        );
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
    } catch (failure) {
      if (_current(generation)) {
        preparing = false;
        _pendingDocumentId = null;
        error = failure.toString();
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

  Future<void> _completion(NarrationPlayback playback, int generation) async {
    try {
      final result = await playback.done;
      if (!_current(generation) || !identical(_playback, playback)) return;
      snapshot = NarrationSnapshot(
        phase: result == NarrationOutcome.completed
            ? NarrationPhase.completed
            : NarrationPhase.stopped,
      );
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
    if (terminal && source != null) {
      final saved = source!;
      unawaited(read(saved.documentId, () async => saved));
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
    await stop();
    source = null;
    snapshot = null;
    _notify();
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    await stop();
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
