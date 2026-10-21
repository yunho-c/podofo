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
  String get key => '$voice:$language:$speed';
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

/// Optional metadata-only capabilities. Audio scheduling remains in MLSR.
abstract interface class NarrationDurationSession {
  NarrationDurationJob planDuration(String text, NarrationSettings settings);
}

abstract interface class NarrationDurationJob {
  Future<NarrationTiming?> get result;
  void cancel();
  Future<void> dispose();
}

abstract interface class NarrationTimedPlayback {
  Future<NarrationTiming?> timing();
}

class NarrationTimingSegment {
  const NarrationTimingSegment({
    required this.start,
    required this.end,
    required this.startFrame,
    required this.predictedFrames,
    this.actualFrames,
  });
  final int start, end, startFrame, predictedFrames;
  final int? actualFrames;
  int get frames => actualFrames ?? predictedFrames;
}

class NarrationTiming {
  NarrationTiming({
    required this.textHash,
    required this.settingsKey,
    required this.sampleRate,
    required this.estimatedFrames,
    this.durationFrames,
    required Iterable<NarrationTimingSegment> segments,
  }) : segments = List.unmodifiable(segments);
  final String textHash, settingsKey;
  final int sampleRate, estimatedFrames;
  final int? durationFrames;
  final List<NarrationTimingSegment> segments;
  int get frames => durationFrames ?? estimatedFrames;
  bool get measured => durationFrames != null;

  /// Approximate source alignment only within a model segment, never word timing.
  double frameAtOffset(int offset) {
    for (final s in segments) {
      if (offset <= s.start) return s.startFrame.toDouble();
      if (offset < s.end) {
        return s.startFrame + s.frames * (offset - s.start) / (s.end - s.start);
      }
    }
    return frames.toDouble();
  }
}

const narrationSpeeds = [0.9, 1.0, 1.1, 1.2, 1.3];
double normalizedNarrationSpeed(double value) =>
    !value.isFinite ? 1.0 : (value.clamp(0.9, 1.3) * 10).round() / 10;
