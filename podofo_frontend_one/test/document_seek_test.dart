import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:podofo_one/src/narration/narration_controller.dart';
import 'package:podofo_one/src/narration/narrator.dart';
import 'package:podofo_one/src/narration/paper_plan.dart';
import 'package:podofo_one/src/narration/paper_sequence.dart';
import 'package:podofo_one/src/narration/source_map.dart';

import 'paper_index_test.dart' as fixture;
import 'paper_timeline_test.dart' as timings;
import 'support/fake_narrator.dart';

class TimedPlayback extends FakeNarrationPlayback
    implements NarrationTimedPlayback {
  TimedPlayback(this.text, this.settings, {required bool paused}) {
    Future<void>(
      () => state(paused ? NarrationPhase.paused : NarrationPhase.playing),
    );
  }
  final String text;
  final NarrationSettings settings;
  bool confirmSeek = true;
  int position = 0;
  void state(NarrationPhase phase, {bool seeking = false}) {
    if (disposed) return;
    events.add(
      NarrationSnapshot(
        phase: phase,
        start: 0,
        end: text.length,
        sampleRate: 100,
        positionFrames: position,
        estimatedFrames: 1000,
        seeking: seeking,
      ),
    );
  }

  @override
  Future<NarrationTiming?> timing() async =>
      timings.timing(text, key: settings.key);
  @override
  void seek(int frame) {
    super.seek(frame);
    if (confirmSeek) {
      Future<void>(() {
        position = frame;
        state(NarrationPhase.paused);
      });
    }
  }

  @override
  void resume() {
    super.resume();
    Future<void>(() => state(NarrationPhase.playing));
  }

  @override
  void pause() {
    super.pause();
    Future<void>(() => state(NarrationPhase.paused));
  }
}

class SeekSession extends timings.TimingSession {
  bool confirmSeek = true;
  @override
  NarrationPlayback speak(
    String text,
    NarrationSettings settings, {
    bool paused = false,
  }) {
    texts.add(text);
    requests.add(settings);
    initialPauses.add(paused);
    final playback = TimedPlayback(text, settings, paused: paused)
      ..confirmSeek = confirmSeek;
    playbacks.add(playback);
    return playback;
  }
}

Future<NarrationController> reader(
  PaperSequence paper,
  SeekSession session, {
  int page = 1,
  SourceAnchor? anchor,
}) async {
  final full = (await paper.start(page: page, anchor: anchor))!;
  final controller = NarrationController(open: (_) async => session);
  await controller.read(
    paper,
    () async => NarrationSource(
      documentId: paper,
      title: 'Paper',
      text: full.text,
      passage: full,
      sequence: paper,
    ),
  );
  await timings.settle();
  return controller;
}

void main() {
  test('pause intent changes during preparation; settings and close cancel pending destinations', () async {
    final paper = fixture.sequence(3), session = SeekSession();
    final controller = await reader(paper, session);
    addTearDown(controller.close);
    session.confirmSeek = false;
    final first = controller.seekDocument(15000000);
    await timings.settle();
    controller.togglePause();
    final playback = session.playbacks.last as TimedPlayback;
    playback.position = playback.lastSeek!;
    playback.state(NarrationPhase.paused);
    await first;
    expect(controller.paused, true);
    expect(playback.resumes, 0);
    final second = controller.seekDocument(25000000);
    await timings.settle();
    await controller.configure(const NarrationSettings(speed: 1.3));
    await second;
    await timings.settle();
    expect(controller.seekingDocument, false);
    expect(paper.pageNumber, 2);
    expect(controller.source!.passage!.anchorAt(0)!.page, 2);
    final third = controller.seekDocument(25000000);
    await timings.settle();
    await controller.close();
    await third;
    expect(session.playbacks.every((p) => p.disposed), true);
  });

  test('same-passage seek reuses speech; cross-passage starts paused then restores intent', () async {
    final paper = fixture.sequence(3), session = SeekSession();
    final controller = await reader(paper, session);
    addTearDown(controller.close);
    final original = session.playbacks.single;
    await controller.seekDocument(5000000);
    expect(session.playbacks.length, 1);
    expect(original.lastSeek, 500);
    expect(original.cancelled, false);
    await controller.seekDocument(15000000);
    expect(original.cancelled, true);
    expect(session.initialPauses.last, true);
    expect(session.playbacks.last.lastSeek, 500);
    expect(session.playbacks.last.resumes, 1);
    expect(paper.pageNumber, 2);
    expect(controller.documentPosition!.microseconds, 15000000);
    controller.togglePause();
    await timings.settle();
    await controller.seekDocument(25000000);
    expect(paper.pageNumber, 3);
    expect(session.playbacks.last.resumes, 0);
    expect(controller.paused, true);
  });

  test('latest seek wins while extraction is blocked, without committing old cursor', () async {
    final gate = Completer<void>();
    var blocked = false;
    final session = SeekSession();
    final nextPaper = fixture.sequence(
      3,
      options: const PaperReadOptions(skipRunningMatter: false),
      extract: (page) async {
        if (blocked && page == 2) await gate.future;
        return fixture.page(page);
      },
    );
    final active = await reader(nextPaper, session);
    addTearDown(active.close);
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    blocked = true;
    final older = active.seekDocument(15000000);
    await timings.settle();
    final latest = active.seekDocument(25000000);
    await timings.settle();
    expect(nextPaper.pageNumber, 1);
    gate.complete();
    await Future.wait([older, latest]);
    expect(nextPaper.pageNumber, 3);
    expect(session.texts.last, startsWith('Page 3.'));
    expect(session.texts.where((s) => s.startsWith('Page 2.')), isEmpty);
  });

  test('Stop during target synthesis leaves the source cursor and bookmark unchanged', () async {
    final paper = fixture.sequence(3), session = SeekSession();
    final controller = await reader(paper, session);
    addTearDown(controller.close);
    final anchor = controller.currentAnchor!;
    final previousPosition = controller.documentPosition!.microseconds;
    session.confirmSeek = false;
    final move = controller.seekDocument(25000000);
    await timings.settle();
    expect(controller.seekingDocument, true);
    expect(paper.pageNumber, 1);
    expect(controller.currentAnchor!.page, anchor.page);
    await controller.stop();
    await move;
    expect(paper.pageNumber, 1);
    expect(session.playbacks.last.cancelled, true);
    expect(controller.currentAnchor!.page, anchor.page);
    expect(controller.preparing, false);
    expect(controller.documentPosition!.microseconds, previousPosition);
  });

  test(
    'changed text fails the frozen seek and does not move the source cursor',
    () async {
      var changed = false;
      final session = SeekSession();
      final targetPaper = fixture.sequence(
        3,
        options: const PaperReadOptions(skipRunningMatter: false),
        extract: (page) async => fixture.page(
          page,
          text: changed && page == 3 ? 'Changed source text.' : null,
        ),
      );
      final active = await reader(targetPaper, session);
      addTearDown(active.close);
      changed = true;
      await active.seekDocument(25000000);
      expect(targetPaper.pageNumber, 1);
      expect(active.error, contains('changed'));
      expect(active.source!.passage!.anchorAt(0)!.page, 1);
      expect(active.documentTimeline!.totalMicroseconds, isNull);
      expect(session.playbacks.length, 1);
    },
  );

  test(
    'seek after Stop stays paused and document endpoint clamps to final frame',
    () async {
      final paper = fixture.sequence(2), session = SeekSession();
      final controller = await reader(paper, session);
      addTearDown(controller.close);
      await controller.stop();
      await controller.seekDocument(20000000);
      expect(paper.pageNumber, 2);
      expect(session.playbacks.last.lastSeek, 999);
      expect(session.playbacks.last.resumes, 0);
      expect(controller.paused, true);
      await controller.seekDocument(-1);
      expect(paper.pageNumber, 1);
      expect(session.playbacks.last.lastSeek, 0);
    },
  );
}
