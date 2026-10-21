import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:podofo_one/src/narration/narrator.dart';
import 'package:podofo_one/src/narration/narration_controller.dart';
import 'package:podofo_one/src/narration/paper_index.dart';
import 'package:podofo_one/src/narration/paper_plan.dart';

import 'paper_index_test.dart' as fixture;
import 'support/fake_narrator.dart';

NarrationTiming timing(
  String text, {
  int frames = 1000,
  bool actual = false,
  String key = ':en:1.0',
}) => NarrationTiming(
  textHash: sha256.convert(utf8.encode(text)).toString(),
  settingsKey: key,
  sampleRate: 100,
  estimatedFrames: frames,
  durationFrames: actual ? frames : null,
  segments: [
    NarrationTimingSegment(
      start: 0,
      end: text.length,
      startFrame: 0,
      predictedFrames: frames,
      actualFrames: actual ? frames : null,
    ),
  ],
);

class TimingJob implements NarrationDurationJob {
  final completion = Completer<NarrationTiming?>();
  bool cancelled = false, disposed = false, ignoreCancel = false;
  @override
  Future<NarrationTiming?> get result => completion.future;
  @override
  void cancel() {
    cancelled = true;
    if (!ignoreCancel && !completion.isCompleted) completion.complete(null);
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

class TimingSession extends FakeNarratorSession
    implements NarrationDurationSession {
  final jobs = <TimingJob>[];
  final planningTexts = <String>[];
  bool automatic = true;
  String? failText;
  @override
  NarrationDurationJob planDuration(String text, NarrationSettings settings) {
    final job = TimingJob();
    jobs.add(job);
    planningTexts.add(text);
    if (text == failText) {
      job.completion.completeError(StateError('unsupported text'));
    } else if (automatic) {
      job.completion.complete(timing(text, key: settings.key));
    }
    return job;
  }
}

Future<void> settle() => pumpEventQueue(times: 100);

void main() {
  test(
    'replacement waits for old duration ownership before new admission',
    () async {
      final session = TimingSession()..automatic = false;
      final controller = NarrationController(open: (_) async => session);
      addTearDown(controller.close);
      final first = fixture.sequence(1), second = fixture.sequence(1);
      final a = (await first.start())!, b = (await second.start())!;
      await controller.read(
        first,
        () async => NarrationSource(
          documentId: first,
          title: 'First',
          text: a.text,
          passage: a,
          sequence: first,
        ),
      );
      await settle();
      final old = session.jobs.single..ignoreCancel = true;
      addTearDown(() {
        if (!old.completion.isCompleted) old.completion.complete(null);
      });
      session.automatic = true;
      final replacement = controller.read(
        second,
        () async => NarrationSource(
          documentId: second,
          title: 'Second',
          text: b.text,
          passage: b,
          sequence: second,
        ),
      );
      await settle();
      expect(session.playbacks.length, 1);
      expect(old.cancelled, true);
      old.completion.complete(null);
      await replacement;
      await settle();
      expect(old.disposed, true);
      expect(session.playbacks.length, 2);
      expect(controller.documentTimeline!.totalMicroseconds, 10000000);
    },
  );

  test('review gaps, explicit skips, and an earlier reference boundary change coverage', () async {
    final paper = fixture.sequence(3), session = TimingSession();
    addTearDown(paper.close);
    await paper.start();
    paper.configureTiming(session, const NarrationSettings());
    await settle();
    paper.index.fail(1, StateError('review required'));
    expect(paper.timeline.snapshot.totalMicroseconds, isNull);
    expect(
      paper.timeline.prefixMicroseconds(
        paper.index.page(2)!.passages.single.id,
      ),
      isNull,
    );
    paper.index.skip(1);
    expect(paper.timeline.snapshot.totalMicroseconds, 20000000);
    expect(
      paper.timeline.prefixMicroseconds(
        paper.index.page(2)!.passages.single.id,
      ),
      0,
    );
    final page = await paper.preview(2);
    paper.index.record(
      PaperPagePlan(
        page: page.page,
        passages: page.passages,
        description: page.description,
        endsPaper: true,
      ),
      paper.options,
    );
    expect(paper.timeline.snapshot.totalMicroseconds, 10000000);
    expect(paper.timeline.retainedTimingCount, 1);
  });

  test(
    'native plans cover whole scope and origin survives repeated slicing',
    () async {
      final paper = fixture.sequence(3), session = TimingSession();
      addTearDown(paper.close);
      final full = (await paper.start(page: 2))!;
      final suffix = full.sliceFrom(5).sliceFrom(3);
      expect(suffix.indexedPassageId, full.indexedPassageId);
      expect(suffix.originalOffset, 8);
      paper.configureTiming(session, const NarrationSettings());
      await settle();
      final state = paper.timeline.snapshot;
      expect(state.totalMicroseconds, 30000000);
      expect(state.plannedPassages, 3);
      expect(state.measured, false);
      expect(session.jobs.every((j) => j.disposed), true);
      expect(paper.cachedPageCount, 1);
      final position = paper.timeline.position(
        full,
        timing(full.text),
        const NarrationSnapshot(
          phase: NarrationPhase.playing,
          sampleRate: 100,
          positionFrames: 250,
        ),
      );
      expect(position!.microseconds, 12500000);
      final sliced = paper.timeline.position(
        suffix,
        timing(suffix.text),
        const NarrationSnapshot(
          phase: NarrationPhase.playing,
          sampleRate: 100,
          positionFrames: 0,
        ),
      );
      expect(sliced!.microseconds, greaterThan(10000000));
      expect(sliced.approximate, true);
    },
  );

  test(
    'missing earlier pages keep position unknown; failed passages are not zero',
    () async {
      final paper = fixture.sequence(3), session = TimingSession();
      addTearDown(paper.close);
      final current = (await paper.start(page: 2))!;
      final entry = paper.index.page(2)!.passages.single;
      paper.timeline.configure(const NarrationSettings());
      paper.timeline.record(entry, timing(current.text));
      expect(paper.timeline.prefixMicroseconds(entry.id), isNull);
      expect(paper.timeline.snapshot.totalMicroseconds, isNull);
      session.failText = fixture.page(1).text.text;
      paper.configureTiming(session, const NarrationSettings());
      await settle();
      expect(paper.timeline.snapshot.failedPassages, 1);
      expect(paper.timeline.snapshot.totalMicroseconds, isNull);
      expect(paper.timeline.snapshot.knownMicroseconds, 20000000);
      session.failText = null;
      paper.retryTiming();
      await settle();
      expect(paper.timeline.snapshot.totalMicroseconds, 30000000);
    },
  );

  test('measured correction wins over a late background prediction', () async {
    final paper = fixture.sequence(1);
    addTearDown(paper.close);
    final full = (await paper.start())!;
    await paper.indexDocument();
    final descriptor = paper.index.snapshot.passages.single;
    paper.timeline.configure(const NarrationSettings());
    paper.timeline.record(
      descriptor,
      timing(full.text, frames: 900, actual: true),
    );
    paper.timeline.record(descriptor, timing(full.text));
    expect(paper.timeline.snapshot.totalMicroseconds, 9000000);
    expect(paper.timeline.snapshot.measured, true);
    paper.timeline.record(
      descriptor,
      timing(full.text.substring(3), frames: 200, actual: true),
    );
    expect(paper.timeline.snapshot.totalMicroseconds, 9000000);
    paper.invalidateTiming(const NarrationSettings(speed: 1.3));
    expect(paper.timeline.snapshot.totalMicroseconds, isNull);
    expect(paper.timeline.retainedTimingCount, 0);
  });

  test(
    'Stop rejects late results, resumes missing work, and close releases jobs',
    () async {
      final paper = fixture.sequence(2),
          session = TimingSession()..automatic = false;
      await paper.start();
      paper.configureTiming(session, const NarrationSettings());
      await settle();
      expect(session.jobs.length, 1);
      final late = session.jobs.single..ignoreCancel = true;
      paper.cancelPending();
      expect(late.cancelled, true);
      late.completion.complete(timing(session.planningTexts.single));
      await settle();
      expect(paper.timeline.retainedTimingCount, 0);
      session.automatic = true;
      paper.configureTiming(session, const NarrationSettings());
      await settle();
      expect(paper.timeline.snapshot.totalMicroseconds, 20000000);
      expect(session.jobs.every((j) => j.disposed), true);
      paper.close();
      expect(paper.index.snapshot.status, PaperIndexStatus.closed);
    },
  );

  test(
    'settings replacement rejects late plans and restart uses new settings',
    () async {
      final paper = fixture.sequence(1),
          session = TimingSession()..automatic = false;
      addTearDown(paper.close);
      await paper.start();
      paper.configureTiming(session, const NarrationSettings());
      await settle();
      final old = session.jobs.single..ignoreCancel = true;
      paper.invalidateTiming(const NarrationSettings(speed: 1.3));
      session.automatic = true;
      paper.configureTiming(session, const NarrationSettings(speed: 1.3));
      old.completion.complete(timing(session.planningTexts.first));
      await settle();
      final entry = paper.index.snapshot.passages.single;
      expect(paper.timeline.timing(entry.id)!.settingsKey, ':en:1.3');
      expect(session.jobs.length, 2);
    },
  );

  test(
    'controller keeps document position on Stop and validates speed presets',
    () async {
      final paper = fixture.sequence(2), session = TimingSession();
      final controller = NarrationController(open: (_) async => session);
      addTearDown(controller.close);
      final full = (await paper.start(page: 2))!;
      await controller.read(
        Object(),
        () async => NarrationSource(
          documentId: paper,
          title: 'Paper',
          text: full.text,
          passage: full,
          sequence: paper,
        ),
      );
      session.playbacks.single.events.add(
        const NarrationSnapshot(
          phase: NarrationPhase.playing,
          sampleRate: 100,
          positionFrames: 300,
        ),
      );
      await settle();
      expect(controller.documentPosition!.microseconds, 13000000);
      await controller.stop();
      expect(controller.documentPosition!.microseconds, 13000000);
      await expectLater(
        controller.configure(const NarrationSettings(speed: 1.4)),
        throwsArgumentError,
      );
      expect(normalizedNarrationSpeed(2), 1.3);
      expect(normalizedNarrationSpeed(0.5), 0.9);
      expect(normalizedNarrationSpeed(double.nan), 1);
      expect(normalizedNarrationSpeed(1.14), 1.1);
    },
  );
}
