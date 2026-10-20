/// App boundary around MLSR. Audio and scheduling remain native-owned.
enum NarrationPhase { preparing, playing, paused, completed, stopped, failed }

enum NarrationOutcome { completed, cancelled }

class NarrationVoice {
  const NarrationVoice(this.id, this.name, this.languages);
  final String id, name;
  final List<String> languages;
}

class NarrationSettings {
  const NarrationSettings({
    this.voice = '',
    this.language = 'en',
    this.speed = 1,
  });
  final String voice, language;
  final double speed;
}

class NarrationSnapshot {
  const NarrationSnapshot({
    required this.phase,
    this.start,
    this.end,
    this.sentenceId,
    this.positionFrames = 0,
    this.durationFrames,
    this.estimatedFrames,
    this.sampleRate = 44100,
    this.seeking = false,
  });
  final NarrationPhase phase;
  final int? start, end, sentenceId;
  final int positionFrames, sampleRate;
  final int? durationFrames, estimatedFrames;
  final bool seeking;

  NarrationSnapshot withPhase(NarrationPhase next) => NarrationSnapshot(
    phase: next,
    start: start,
    end: end,
    sentenceId: sentenceId,
    positionFrames: positionFrames,
    durationFrames: durationFrames,
    estimatedFrames: estimatedFrames,
    sampleRate: sampleRate,
    seeking: seeking,
  );
}

class NarrationSentence {
  const NarrationSentence(this.id, this.start, this.end);
  final int id, start, end;
}

class NarrationNavigation {
  const NarrationNavigation({this.boundary = false, this.replacement});
  final bool boundary;
  final NarrationPlayback? replacement;
}

abstract interface class NarrationPlayback {
  Stream<NarrationSnapshot> get states;
  Future<NarrationOutcome> get done;
  Future<List<NarrationSentence>?> sentences();
  void pause();
  void resume();
  void cancel();
  void seek(int frame);
  NarrationNavigation navigate({required bool forward});
  NarrationNavigation navigateToSentence(int id);
  Future<void> dispose();
}

abstract interface class NarratorSession {
  Future<List<NarrationVoice>> voices();
  NarrationPlayback speak(
    String text,
    NarrationSettings settings, {
    bool paused = false,
  });
  Future<void> dispose();
}

typedef NarratorFactory = Future<NarratorSession> Function(
  void Function(String message) onProgress,
);
