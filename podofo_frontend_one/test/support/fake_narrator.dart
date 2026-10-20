import 'dart:async';

import 'package:podofo_one/src/narration/narrator.dart';

class FakeNarratorSession implements NarratorSession {
  final texts = <String>[];
  final playbacks = <FakeNarrationPlayback>[];
  final initialPauses = <bool>[];
  final requests = <NarrationSettings>[];
  int disposals = 0;
  Object? voiceFailure;

  @override
  Future<List<NarrationVoice>> voices() async {
    if (voiceFailure != null) throw voiceFailure!;
    return const [
      NarrationVoice('supertonic3:M1', 'Alex', ['en', 'ko']),
    ];
  }

  @override
  NarrationPlayback speak(
    String text,
    NarrationSettings settings, {
    bool paused = false,
  }) {
    texts.add(text);
    requests.add(settings);
    initialPauses.add(paused);
    final playback = FakeNarrationPlayback();
    playbacks.add(playback);
    return playback;
  }

  @override
  Future<void> dispose() async {
    disposals++;
  }
}

class FakeNarrationPlayback implements NarrationPlayback {
  final events = StreamController<NarrationSnapshot>.broadcast(sync: true);
  final completion = Completer<NarrationOutcome>();
  int pauses = 0, resumes = 0;
  bool cancelled = false, disposed = false;
  Completer<void>? disposalGate;
  List<NarrationSentence>? sentencePlan = const [
    NarrationSentence(0, 0, 6),
    NarrationSentence(1, 7, 14),
  ];
  NarrationNavigation navigation = const NarrationNavigation(boundary: true);
  int? lastSeek;
  bool? lastForward;
  void emit(NarrationPhase phase) =>
      events.add(NarrationSnapshot(phase: phase));
  @override
  Stream<NarrationSnapshot> get states => events.stream;
  @override
  Future<NarrationOutcome> get done => completion.future;
  @override
  Future<List<NarrationSentence>?> sentences() async => sentencePlan;
  @override
  void pause() {
    pauses++;
  }

  @override
  void resume() {
    resumes++;
  }

  @override
  void cancel() {
    cancelled = true;
    if (!completion.isCompleted) {
      completion.complete(NarrationOutcome.cancelled);
    }
  }

  @override
  void seek(int frame) {
    lastSeek = frame;
  }

  @override
  NarrationNavigation navigate({required bool forward}) {
    lastForward = forward;
    return navigation;
  }

  @override
  NarrationNavigation navigateToSentence(int id) =>
      const NarrationNavigation(boundary: true);
  @override
  Future<void> dispose() async {
    if (disposed) return;
    disposed = true;
    cancel();
    await events.close();
    await disposalGate?.future;
  }
}
