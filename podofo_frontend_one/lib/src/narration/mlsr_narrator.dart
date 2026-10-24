import 'dart:ffi';
import 'dart:io';

import 'package:mlsr_app_models/app_models.dart';
import 'package:mlsr_flutter/mlsr_flutter.dart';

import 'narrator.dart';
import 'duration_profile.dart';

String? narrationUnavailableReason() =>
    Platform.isMacOS && Abi.current() == Abi.macosArm64
    ? null
    : 'Paper listening is available on macOS Apple Silicon.';

class MlsrNarrator implements NarratorSession, NarrationDurationSession {
  /// Takes ownership of an already-open facade, also useful for release probes.
  MlsrNarrator.fromTts(this._tts, {this._volume = 1, this.profile});
  final DurationProfile? profile;
  final Tts _tts;
  final double _volume;

  static Future<NarratorSession> open(
    void Function(String message) onProgress, {
    double volume = 1,
  }) async => MlsrNarrator.fromTts(
    await FlutterMlsr.openTts(
      model: AppModels.supertonic3,
      onProgress: (progress) => onProgress(switch (progress.stage) {
        ModelLoadStage.locating => 'Finding voices…',
        ModelLoadStage.waiting => 'Waiting for voice preparation…',
        ModelLoadStage.copying => 'Preparing voices…',
        ModelLoadStage.verifying => 'Checking voices…',
        ModelLoadStage.loading => 'Loading voices…',
      }),
    ),
    volume: volume,
  );

  @override
  Future<List<NarrationVoice>> voices() async => [
    for (final voice in await _tts.getVoices())
      NarrationVoice(voice.id, voice.displayName, voice.languages),
  ];

  @override
  NarrationPlayback speak(
    String text,
    NarrationSettings settings, {
    bool paused = false,
  }) => _MlsrPlayback(
    _tts.speak(
      text,
      request: RequestOptions(
        voice: settings.voice,
        locale: settings.language,
        fallback: VoiceFallback.sameLanguage,
        speakingRate: settings.speed,
      ),
      options: SpeechOptions(
        onDemandSeeking: true,
        paused: paused,
        volume: _volume,
      ),
    ),
  );

  @override
  NarrationDurationJob planDuration(String text, NarrationSettings settings) =>
      _MlsrDurationJob(
        _tts.planDuration(
          text,
          options: RequestOptions(
            voice: settings.voice,
            locale: settings.language,
            fallback: VoiceFallback.sameLanguage,
            speakingRate: settings.speed,
          ),
        ),
        profile,
      );

  @override
  Future<void> dispose() => _tts.dispose();
}

class _MlsrPlayback implements NarrationPlayback, NarrationTimedPlayback {
  _MlsrPlayback(this._speech);
  final Speech _speech;
  @override
  Future<NarrationTiming?> timing() async {
    final value = await _speech.timeline();
    return value == null ? null : _timing(value);
  }

  @override
  Stream<NarrationSnapshot> get states => _speech.states.map(
    (state) => NarrationSnapshot(
      phase: switch (state.playback) {
        PlaybackPhase.queued ||
        PlaybackPhase.buffering => NarrationPhase.preparing,
        PlaybackPhase.playing ||
        PlaybackPhase.draining => NarrationPhase.playing,
        PlaybackPhase.paused => NarrationPhase.paused,
        PlaybackPhase.ended => NarrationPhase.completed,
        PlaybackPhase.stopped => NarrationPhase.stopped,
        PlaybackPhase.failed => NarrationPhase.failed,
      },
      start: state.activeTextRange?.start,
      end: state.activeTextRange?.end,
      sentenceId: state.activeTextRange?.sentenceId,
      positionFrames: state.positionFrame,
      durationFrames: state.durationFrames,
      estimatedFrames: state.estimatedFrames,
      sampleRate: state.format.sampleRate,
      seeking: state.seeking,
    ),
  );

  @override
  Future<NarrationOutcome> get done async =>
      (await _speech.done).kind == OutcomeKind.completed
      ? NarrationOutcome.completed
      : NarrationOutcome.cancelled;

  @override
  Future<List<NarrationSentence>?> sentences() async {
    final plan = await _speech.plan();
    return plan == null
        ? null
        : [
            for (final sentence in plan.sentences)
              NarrationSentence(
                sentence.id,
                sentence.utf16.start,
                sentence.utf16.end,
              ),
          ];
  }

  @override
  void pause() => _speech.pause();
  @override
  void resume() => _speech.resume();
  @override
  void cancel() => _speech.cancel();
  @override
  void seek(int frame) => _speech.seek(frame);
  NarrationNavigation _navigation(Navigation result) => NarrationNavigation(
    boundary: result.kind == NavigationKind.boundary,
    replacement: result.speech == null ? null : _MlsrPlayback(result.speech!),
  );
  @override
  NarrationNavigation navigate({required bool forward}) => _navigation(
    forward ? _speech.nextSentence() : _speech.previousSentence(),
  );
  @override
  NarrationNavigation navigateToSentence(int id) =>
      _navigation(_speech.navigateToSentence(id));
  @override
  Future<void> dispose() => _speech.dispose();
}

NarrationTiming _timing(DurationPlan plan) => NarrationTiming(
  textHash: plan.textSha256,
  settingsKey:
      '${plan.manifestSha256}:${plan.voice}:${plan.language}:${plan.speakingRate}:${plan.backend.steps}:${plan.backend.seed}',
  sampleRate: plan.format.sampleRate,
  estimatedFrames: plan.estimatedFrames,
  durationFrames: plan.durationFrames,
  segments: [
    for (final s in plan.segments)
      NarrationTimingSegment(
        start: s.utf16.start,
        end: s.utf16.end,
        startFrame: s.startFrame,
        predictedFrames: s.estimatedFrames,
        actualFrames: s.actualFrames,
      ),
  ],
);

class _MlsrDurationJob implements NarrationDurationJob {
  _MlsrDurationJob(this.job, this.profile);
  final DurationProfile? profile;
  final DurationPlanningJob job;
  @override
  Future<NarrationTiming?> get result async {
    final waitStart = profile?.begin();
    final completion = await job.done;
    if (waitStart != null) profile!.end('sdk_done', waitStart);
    if (completion.kind != OutcomeKind.completed) return null;
    final metadataStart = profile?.begin();
    final plan = await job.timeline();
    if (metadataStart != null) profile!.end('sdk_timeline', metadataStart);
    final convertStart = profile?.begin();
    final result = plan == null ? null : _timing(plan);
    if (convertStart != null) profile!.end('timing_conversion', convertStart);
    return result;
  }

  @override
  void cancel() => job.cancel();
  @override
  Future<void> dispose() => job.dispose();
}
