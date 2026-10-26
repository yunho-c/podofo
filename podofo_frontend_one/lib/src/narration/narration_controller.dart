import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'narrator.dart';
import 'source_map.dart';
import 'narration_sequence.dart';
import 'paper_sequence.dart';
import 'paper_timeline.dart';

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
  SourceAnchor? _lastAnchor;
  Completer<void>? _movement;
  NarrationPlayback? _positioning, _readingPlanFor;
  NarratorSession? _session;
  Future<void>? _opening, _closing;
  NarrationPlayback? _playback;
  StreamSubscription<NarrationSnapshot>? _subscription;
  final Set<Future<void>> _retiring = {};
  int _generation = 0;
  Object? _pendingDocumentId;
  bool _closed = false, _pauseWhenReady = false;
  NarrationSource? source;

  /// Optional caller identity, allowing a feature to dismiss only its own work.
  /// Other read requests replace this identity before asynchronous resolution.
  Object? _requestOwner;
  Object? get requestOwner => _requestOwner;
  NarrationSnapshot? snapshot;
  PaperSequence? _timedSequence;
  _DocumentSeek? _documentSeek;
  bool get seekingDocument => _documentSeek != null;
  PaperSeekTarget? get documentSeekTarget => _documentSeek?.target;
  // A separate notification path repaints previews without invoking follow-text.
  final _scrubPreview =
      ValueNotifier<({PaperSequence paper, PaperSeekTarget? target})?>(null);
  ValueListenable<({PaperSequence paper, PaperSeekTarget? target})?>
  get scrubPreview => _scrubPreview;
  bool get previewingDocument => _scrubPreview.value != null || seekingDocument;

  void previewDocumentSeek(PaperSeekTarget? target) {
    final paper = _timedSequence;
    if (_closed || paper == null) return;
    final old = _scrubPreview.value;
    if (identical(old?.paper, paper) &&
        old?.target?.passage.id == target?.passage.id &&
        old?.target?.start == target?.start &&
        old?.target?.end == target?.end) {
      return;
    }
    _scrubPreview.value = (paper: paper, target: target);
  }

  void clearDocumentPreview() => _scrubPreview.value = null;

  ({NarrationPassage passage, int start, int end})? get previewHighlight {
    final preview = _scrubPreview.value;
    final target = preview != null ? preview.target : documentSeekTarget;
    final paper = preview?.paper ?? _timedSequence;
    if (target == null || paper == null || !identical(paper, _timedSequence)) {
      return null;
    }
    final passage = paper.cachedSeekPassage(target);
    return passage == null
        ? null
        : (passage: passage, start: target.start, end: target.end);
  }

  bool _resumePending = false;
  NarrationTiming? _currentTiming;
  NarrationPlayback? _readingTimingFor;
  (int?, int?, int?)? _timingKey;
  PaperTimelineSnapshot? get documentTimeline =>
      _timedSequence?.timeline.snapshot;
  DocumentPosition? get documentPosition {
    final operation = _documentSeek;
    if (operation != null) {
      final passage = operation.previousSource.passage;
      return passage == null
          ? null
          : _timedSequence?.timeline.position(
              passage,
              operation.previousTiming,
              operation.previousSnapshot,
            );
    }
    final passage = source?.passage;
    return passage == null
        ? null
        : _timedSequence?.timeline.position(passage, _currentTiming, snapshot);
  }

  void _listenDocument(NarrationSequence? sequence) {
    final paper = sequence is PaperSequence ? sequence : null;
    if (identical(paper, _timedSequence)) return;
    _timedSequence?.timeline.removeListener(_notify);
    _timedSequence = paper;
    paper?.timeline.addListener(_notify);
  }

  Future<void> _captureTiming(
    NarrationPlayback playback,
    int generation,
  ) async {
    if (playback is! NarrationTimedPlayback || _readingTimingFor != null) {
      return;
    }
    _readingTimingFor = playback;
    try {
      final value = await (playback as NarrationTimedPlayback).timing();
      if (!_current(generation) ||
          !identical(playback, _playback) ||
          value == null) {
        return;
      }
      _currentTiming = value;
      final operation = _documentSeek;
      if (operation != null && operation.frame == null) {
        operation.frame = operation.target.frameIn(value);
        playback.seek(operation.frame!);
      }
      final passage = source?.passage, paper = _timedSequence;
      if (passage != null && paper != null && passage.originalOffset == 0) {
        final descriptor = paper.index.snapshot.passages
            .where((p) => p.id == passage.indexedPassageId)
            .firstOrNull;
        if (descriptor != null) paper.timeline.record(descriptor, value);
      }
      _notify();
    } catch (failure) {
      if (_documentSeek case final operation?) {
        _failDocumentSeek(operation, failure);
      }
      // Timing observation cannot interrupt ordinary speech. Background planning retains
      // typed failures and coverage independently.
    } finally {
      if (identical(_readingTimingFor, playback)) _readingTimingFor = null;
    }
  }

  List<NarrationVoice> voices = const [];
  NarrationSettings settings = const NarrationSettings();
  String? error;
  String preparation = '';
  bool preparing = false;
  bool followText = true;
  int followRequest = 0;
  List<NarrationSentence> sentences = const [];
  SourceAnchor? get currentAnchor =>
      _lastAnchor ?? source?.passage?.anchorAt(snapshot?.start ?? 0);

  bool get available => unavailableReason == null;
  bool get active => preparing || (_playback != null && !terminal);
  bool get paused => preparing
      ? _pauseWhenReady
      : _pauseWhenReady ||
            (!_resumePending && snapshot?.phase == NarrationPhase.paused);
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
    Object? owner,
  }) async {
    if (_closed) return;
    if (!available) {
      error = unavailableReason;
      _notify();
      return;
    }
    final generation = ++_generation;
    _requestOwner = owner;
    _finishMovement();
    _remember();
    if (!keepSequence) {
      source?.sequence?.close();
    } else {
      source?.sequence?.cancelPending();
    }
    _retireTiming();
    _pendingDocumentId = documentId;
    _retireCurrent();
    preparing = true;
    _pauseWhenReady = false;
    error = null;
    snapshot = null;
    sentences = const [];
    source = null;
    _listenDocument(null);
    _lastAnchor = null;
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
        _pauseWhenReady = false;
        snapshot = const NarrationSnapshot(phase: NarrationPhase.failed);
        _notify();
      }
    }
  }

  Future<void> _start(
    NarrationSource next,
    int generation, {
    bool lastSentence = false,
  }) async {
    if (next.text.trim().isEmpty) {
      throw StateError('Select readable text first.');
    }
    if (utf8.encode(next.text).length > 64 * 1024) {
      throw StateError('This selection is too long. Select a shorter passage.');
    }
    source = next;
    _listenDocument(next.sequence);
    if (_documentSeek == null) _lastAnchor = null;
    preparation = _documentSeek == null
        ? 'Loading voices…'
        : 'Preparing reading position…';
    _notify();
    await _load();
    await _joinRetiring();
    if (!_current(generation)) return;
    final playback = _session!.speak(
      next.text,
      settings,
      paused: lastSentence || _pauseWhenReady || _documentSeek != null,
    );
    _positioning = lastSentence ? playback : null;
    preparing = lastSentence || _documentSeek != null;
    if (lastSentence) preparation = 'Finding the previous sentence…';
    _pendingDocumentId = null;
    _observe(playback, generation);
    if (_documentSeek != null && playback is! NarrationTimedPlayback) {
      throw StateError('Native timing is unavailable for document seeking.');
    }
    if (_documentSeek == null) _prepareAhead(next.sequence);
  }

  void _prepareAhead(NarrationSequence? sequence) {
    final session = _session;
    if (sequence is PaperSequence && session is NarrationDurationSession) {
      sequence.configureTiming(session as NarrationDurationSession, settings);
    }
    if (sequence != null) unawaited(_prepareNext(sequence));
    if (sequence is DocumentIndexingSequence) {
      unawaited(_indexDocument(sequence as DocumentIndexingSequence));
    }
  }

  Future<void> _indexDocument(DocumentIndexingSequence sequence) async {
    try {
      await sequence.indexDocument();
    } catch (_) {
      // Index failures belong to page coverage, not the active audio request.
    }
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
    // A missing native range (loading, stop or failure) is not a new position.
    final value = source, anchor = _lastAnchor;
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

  void _finishMovement() {
    final movement = _movement;
    _movement = null;
    movement?.complete();
  }

  Future<void> movePassage(int direction, {bool lastSentence = false}) async {
    final previous = source, sequence = source?.sequence;
    if (previous == null || sequence == null || _closed || preparing) return;
    var generation = _generation;
    _remember();
    final keepPaused = paused;
    _pauseWhenReady = keepPaused;
    final movement = _movement = Completer<void>();
    preparing = true;
    preparation = direction < 0
        ? 'Preparing the previous passage…'
        : 'Preparing the next passage…';
    error = null;
    _notify();
    try {
      // Preserve the handle until the sequence confirms a destination. Native
      // completion waits for this lookup so it cannot also advance the cursor.
      if (!terminal && !keepPaused) _playback?.pause();
      final next = await sequence.move(direction);
      if (!_current(generation)) return;
      if (next == null) {
        preparing = false;
        if (direction > 0) {
          ++_generation;
          _retireCurrent();
          _pauseWhenReady = false;
          snapshot =
              snapshot?.withPhase(NarrationPhase.completed) ??
              const NarrationSnapshot(phase: NarrationPhase.completed);
        } else if (!terminal) {
          if (lastSentence && sentences.isNotEmpty) {
            _acceptNavigation(
              _playback!.navigateToSentence(sentences.first.id),
            );
          }
          if (!_pauseWhenReady) _playback?.resume();
        }
        _notify();
        return;
      }
      generation = ++_generation;
      _retireCurrent();
      _finishMovement();
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
        lastSentence: lastSentence,
      );
    } catch (failure) {
      if (_current(generation)) {
        preparing = false;
        _retireCurrent();
        _pauseWhenReady = false;
        error = failure.toString();
        snapshot =
            snapshot?.withPhase(NarrationPhase.failed) ??
            const NarrationSnapshot(phase: NarrationPhase.failed);
        _notify();
      }
    } finally {
      if (identical(_movement, movement)) _finishMovement();
    }
  }

  void _observe(NarrationPlayback playback, int generation) {
    _playback = playback;
    _currentTiming = null;
    _readingTimingFor = null;
    _timingKey = null;
    _subscription = playback.states.listen(
      (value) {
        if (!_current(generation) || !identical(_playback, playback)) return;
        snapshot = value;
        final key = (value.start, value.estimatedFrames, value.durationFrames);
        if (value.estimatedFrames != null &&
            key != _timingKey &&
            _readingTimingFor == null) {
          _timingKey = key;
          unawaited(_captureTiming(playback, generation));
        }
        if (_documentSeek case final operation?) {
          if (operation.frame != null &&
              !value.seeking &&
              value.positionFrames == operation.frame &&
              (value.phase == NarrationPhase.paused ||
                  value.phase == NarrationPhase.playing)) {
            try {
              if (operation.destination case final destination?) {
                _timedSequence!.commitSeek(destination);
              }
              operation.timer?.cancel();
              preparing = false;
              _lastAnchor = source?.passage?.anchorAt(
                value.start ?? operation.target.start,
              );
              _remember();
              _documentSeek = null;
              operation.complete();
              if (!_pauseWhenReady) {
                try {
                  _resumePending = true;
                  playback.resume();
                } catch (failure) {
                  _resumePending = false;
                  _pauseWhenReady = true;
                  error =
                      'Reached the reading position but could not resume: $failure';
                }
              }
              _prepareAhead(source?.sequence);
            } catch (failure) {
              _failDocumentSeek(operation, failure);
              return;
            }
          }
        }
        if (_documentSeek == null &&
            value.start != null &&
            !identical(_positioning, playback)) {
          _lastAnchor = source?.passage?.anchorAt(value.start!);
          _remember();
        }
        if ((sentences.isEmpty || identical(_positioning, playback)) &&
            !identical(_readingPlanFor, playback)) {
          unawaited(_updatePlan(playback, generation));
        }
        if (!preparing && value.phase == NarrationPhase.playing) {
          _resumePending = false;
          _pauseWhenReady = false;
        }
        _notify();
      },
      onError: (Object failure) {
        if (_current(generation)) {
          if (_documentSeek case final operation?) {
            _failDocumentSeek(operation, failure);
          } else {
            error = failure.toString();
            _notify();
          }
        }
      },
    );
    unawaited(_completion(playback, generation));
    _notify();
  }

  Future<void> _updatePlan(NarrationPlayback playback, int generation) async {
    _readingPlanFor = playback;
    try {
      final plan = await playback.sentences();
      if (_current(generation) &&
          identical(_playback, playback) &&
          plan != null) {
        sentences = List.unmodifiable(plan);
        if (identical(_positioning, playback) &&
            (snapshot?.durationFrames ?? snapshot?.estimatedFrames ?? 0) > 0) {
          if (plan.isEmpty) {
            throw StateError('No sentence positions available.');
          }
          final navigation = playback.navigateToSentence(plan.last.id);
          if (navigation.boundary) {
            throw StateError('The previous sentence is no longer available.');
          }
          _positioning = null;
          preparing = false;
          _acceptNavigation(navigation);
          if (!_pauseWhenReady) _playback?.resume();
        }
        _notify();
      }
    } catch (failure) {
      if (_current(generation) && identical(_playback, playback)) {
        error = 'Could not read sentence positions: $failure';
        if (identical(_positioning, playback)) {
          preparing = false;
          ++_generation;
          _retireCurrent();
          _pauseWhenReady = false;
          snapshot = const NarrationSnapshot(phase: NarrationPhase.failed);
        }
        _notify();
      }
    } finally {
      if (identical(_readingPlanFor, playback)) _readingPlanFor = null;
    }
  }

  void setFollowText(bool value) {
    followText = value;
    _notify();
  }

  /// An action, including when already following: reveal the current sentence.
  void resumeFollowing() {
    followText = true;
    followRequest++;
    _notify();
  }

  void navigate({required bool forward}) {
    if (preparing || _closed) return;
    final playback = _playback;
    if (playback == null) {
      unawaited(movePassage(forward ? 1 : -1, lastSentence: !forward));
      return;
    }
    if (sentences.isEmpty) return;
    try {
      final result = playback.navigate(forward: forward);
      if (result.boundary && source?.sequence != null) {
        unawaited(movePassage(forward ? 1 : -1, lastSentence: !forward));
      } else if (result.boundary && !forward) {
        _acceptNavigation(playback.navigateToSentence(sentences.first.id));
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

  /// Navigate through frozen source identity. Newer navigation, Stop and close
  /// invalidate all callbacks; only a confirmed native target commits the cursor.
  Future<void> seekDocument(int microseconds) {
    final target = _timedSequence?.timeline.targetAt(microseconds);
    return target == null ? Future<void>.value() : seekToTarget(target);
  }

  /// Accept a source target captured from a frozen drag scale.
  Future<void> seekToTarget(PaperSeekTarget target) async {
    final paper = _timedSequence;
    final pending = _documentSeek;
    final previous = pending?.previousSource ?? source;
    if (_closed || paper == null || previous == null) return;
    if (!paper.timeline.accepts(target)) {
      error = 'Document timing changed while selecting a reading position. Try again.';
      _notify();
      return;
    }
    final keepPaused = preparing
        ? paused
        : terminal || _playback == null || paused;
    final oldSnapshot = pending?.previousSnapshot ?? snapshot;
    final oldTiming = pending?.previousTiming ?? _currentTiming;
    final oldAnchor = pending?.previousAnchor ?? currentAnchor;
    _remember();
    final current = _playback, currentTiming = _currentTiming;
    if (pending == null &&
        !terminal &&
        current != null &&
        currentTiming != null &&
        previous.passage?.originalOffset == 0 &&
        previous.passage?.indexedPassageId == target.passage.id) {
      final operation = _DocumentSeek(
        target,
        previous,
        oldSnapshot,
        oldTiming,
        oldAnchor,
      );
      _documentSeek = operation;
      _pauseWhenReady = keepPaused;
      preparing = true;
      preparation = 'Preparing reading position…';
      error = null;
      operation.timer = Timer(const Duration(seconds: 30), () {
        _failDocumentSeek(
          operation,
          StateError(
            'The reading position took too long to prepare. Try again.',
          ),
        );
      });
      try {
        operation.frame = target.frameIn(currentTiming);
        current.pause();
        current.seek(operation.frame!);
        _notify();
        await operation.done.future;
      } catch (failure) {
        _failDocumentSeek(operation, failure);
      }
      return;
    }
    final generation = ++_generation;
    _finishMovement();
    paper.cancelPending();
    _retireTiming();
    _retireCurrent();
    source = previous;
    final operation = _DocumentSeek(
      target,
      previous,
      oldSnapshot,
      oldTiming,
      oldAnchor,
    );
    _documentSeek = operation;
    _lastAnchor = oldAnchor;
    _pauseWhenReady = keepPaused;
    preparing = true;
    preparation = 'Preparing reading position…';
    error = null;
    operation.timer = Timer(const Duration(seconds: 30), () {
      _failDocumentSeek(
        operation,
        StateError('The reading position took too long to prepare. Try again.'),
      );
    });
    _notify();
    try {
      final destination = await paper.resolveSeek(target);
      await _joinRetiring();
      if (!_current(generation) || !identical(_documentSeek, operation)) return;
      operation.destination = destination;
      snapshot = null;
      sentences = const [];
      await _start(
        NarrationSource(
          documentId: previous.documentId,
          title: previous.title,
          text: destination.passage.text,
          passage: destination.passage,
          sequence: paper,
        ),
        generation,
      );
      await operation.done.future;
    } catch (failure) {
      if (_current(generation)) _failDocumentSeek(operation, failure);
    }
  }

  void _failDocumentSeek(_DocumentSeek operation, Object failure) {
    if (!identical(_documentSeek, operation)) return;
    ++_generation;
    source?.sequence?.cancelPending();
    _retireTiming();
    _retireCurrent();
    source = operation.previousSource;
    _lastAnchor = operation.previousAnchor;
    _currentTiming = operation.previousTiming;
    snapshot =
        operation.previousSnapshot?.withPhase(NarrationPhase.stopped) ??
        const NarrationSnapshot(phase: NarrationPhase.stopped);
    preparing = false;
    _pauseWhenReady = false;
    error = 'Could not move to that reading position: $failure';
    _notify();
  }

  void seek(int frame) {
    if (preparing) return;
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
    if (!narrationSpeeds.contains(next.speed)) {
      throw ArgumentError('Speaking speed must be 0.9–1.3 in steps of 0.1.');
    }
    if (next.voice == settings.voice &&
        next.language == settings.language &&
        next.speed == settings.speed) {
      return;
    }
    settings = next;
    _timedSequence?.invalidateTiming(next);
    _currentTiming = null;
    final previous = _documentSeek?.previousSource ?? source;
    if (previous != null && active) {
      final keepPaused = paused;
      final replacement = previous.fromOffset(
        _documentSeek?.previousSnapshot?.start ?? snapshot?.start ?? 0,
      );
      final work = read(
        previous.documentId,
        () async => replacement,
        keepSequence: true,
        owner: requestOwner,
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
      if (_current(generation) &&
          identical(_playback, playback) &&
          _documentSeek != null) {
        _failDocumentSeek(
          _documentSeek!,
          StateError('Speech ended before the reading position was ready.'),
        );
        return;
      }
      await _movement?.future;
      if (!_current(generation) || !identical(_playback, playback)) return;
      preparing = false;
      _positioning = null;
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
      await _movement?.future;
      if (_current(generation) &&
          identical(_playback, playback) &&
          _documentSeek != null) {
        _failDocumentSeek(_documentSeek!, failure);
        return;
      }
      if (_current(generation) && identical(_playback, playback)) {
        preparing = false;
        _positioning = null;
        error = failure.toString();
        snapshot =
            snapshot?.withPhase(NarrationPhase.failed) ??
            const NarrationSnapshot(phase: NarrationPhase.failed);
        _notify();
      }
    }
  }

  void togglePause() {
    if (_closed) return;
    if (terminal && !preparing && source != null) {
      final saved = source!;
      unawaited(
        read(
          saved.documentId,
          () async => saved,
          keepSequence: true,
          owner: requestOwner,
        ),
      );
      return;
    }
    _pauseWhenReady = !paused;
    _resumePending = false;
    if (preparing) {
      _notify();
      return;
    }
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
    clearDocumentPreview();
    _resumePending = false;
    final pending = _documentSeek;
    pending?.complete();
    _documentSeek = null;
    if (pending != null) {
      source = pending.previousSource;
      snapshot = pending.previousSnapshot;
      _lastAnchor = pending.previousAnchor;
      _currentTiming = pending.previousTiming;
    }
    final playback = _playback;
    final subscription = _subscription;
    _playback = null;
    _positioning = null;
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

  void _retireTiming() {
    final sequence = source?.sequence;
    if (sequence is! PaperSequence) return;
    late final Future<void> work;
    work = sequence.timingIdle.whenComplete(() => _retiring.remove(work));
    _retiring.add(work);
  }

  Future<void> _joinRetiring() async {
    await Future.wait(_retiring.toList());
  }

  Future<void> stop() async {
    _remember();
    source?.sequence?.cancelPending();
    _retireTiming();
    ++_generation;
    _finishMovement();
    preparing = false;
    _pendingDocumentId = null;
    _pauseWhenReady = false;
    _retireCurrent();
    snapshot =
        snapshot?.withPhase(NarrationPhase.stopped) ??
        const NarrationSnapshot(phase: NarrationPhase.stopped);
    _notify();
    await _joinRetiring();
  }

  /// Dismisses narration without disposing the reusable speech engine.
  Future<void> dismiss() async {
    _requestOwner = null;
    final stopping = stop();
    final generation = _generation;
    source?.sequence?.close();
    source = null;
    _listenDocument(null);
    _lastAnchor = null;
    snapshot = null;
    sentences = const [];
    _currentTiming = null;
    _timingKey = null;
    error = null;
    preparation = '';
    _notify();
    await stopping;
    // A cleanup failure must not reopen a dismissed panel, nor clear errors
    // belonging to narration started while the old playback was retiring.
    if (_generation == generation) {
      error = null;
      _notify();
    }
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
    _requestOwner = null;
    source = null;
    _listenDocument(null);
    _lastAnchor = null;
    snapshot = null;
    _notify();
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    await stop();
    _listenDocument(null);
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

class _DocumentSeek {
  _DocumentSeek(
    this.target,
    this.previousSource,
    this.previousSnapshot,
    this.previousTiming,
    this.previousAnchor,
  );
  final PaperSeekTarget target;
  final NarrationSource previousSource;
  final NarrationSnapshot? previousSnapshot;
  final NarrationTiming? previousTiming;
  final SourceAnchor? previousAnchor;
  final done = Completer<void>();
  ResolvedPaperSeek? destination;
  Timer? timer;
  int? frame;
  void complete() {
    timer?.cancel();
    if (!done.isCompleted) done.complete();
  }
}
