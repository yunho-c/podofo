import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:podofo_one/src/narration/narration_controller.dart';
import 'package:podofo_one/src/narration/narration_sequence.dart';
import 'package:podofo_one/src/narration/narrator.dart';
import 'package:podofo_one/src/narration/source_map.dart';

import 'support/fake_narrator.dart';

class _Sequence implements NarrationSequence {
  int cursor = 0;
  final passages = [
    NarrationPassage('First. Second.', [
      const SpokenSpan(0, 7, SourceAnchor(1, 0, 'page'), 7, []),
      const SpokenSpan(7, 14, SourceAnchor(1, 7, 'page'), 14, []),
    ]),
    NarrationPassage('Third. Fourth.', []),
  ];
  Completer<void>? gate;
  @override
  Future<NarrationPassage?> move(int direction) async {
    await gate?.future;
    final next = cursor + direction;
    if (next < 0 || next >= passages.length) return null;
    cursor = next;
    return passages[cursor];
  }

  @override
  Future<void> prepareNext() async {}
  @override
  void cancelPending() {}
  @override
  void close() {}
}

Future<void> flush() => pumpEventQueue(times: 10);

NarrationSource _source(Object document, _Sequence sequence) => NarrationSource(
  documentId: document,
  title: 'Paper',
  text: sequence.passages[sequence.cursor].text,
  passage: sequence.passages[sequence.cursor],
  sequence: sequence,
);

void ready(
  FakeNarrationPlayback playback, {
  bool paused = false,
  int start = 0,
}) {
  playback.events.add(
    NarrationSnapshot(
      phase: paused ? NarrationPhase.paused : NarrationPhase.playing,
      start: start,
      end: start + 7,
      estimatedFrames: 1000,
    ),
  );
}

void main() {
  test(
    'pause intent during a boundary lookup survives native pause states',
    () async {
      final session = FakeNarratorSession(),
          document = Object(),
          sequence = _Sequence();
      final controller = NarrationController(open: (_) async => session);
      addTearDown(controller.close);
      await controller.read(document, () async => _source(document, sequence));
      final playback = session.playbacks.single;
      ready(playback);
      await flush();
      sequence.gate = Completer<void>();
      controller.navigate(forward: false);
      ready(playback, paused: true);
      expect(controller.paused, false); // Native lookup pause is temporary.
      controller.togglePause();
      expect(controller.paused, true);
      sequence.gate!.complete();
      await flush();
      expect(playback.resumes, 0);
      expect(controller.paused, true);
      expect(controller.status, 'Paused');
    },
  );

  test('a stale sentence-plan query cannot block a replacement plan', () async {
    final session = FakeNarratorSession(),
        document = Object(),
        sequence = _Sequence();
    final controller = NarrationController(open: (_) async => session);
    addTearDown(controller.close);
    await controller.read(document, () async => _source(document, sequence));
    final old = session.playbacks.single;
    old.planGate = Completer<List<NarrationSentence>?>();
    ready(old);
    await flush();
    await controller.read(document, () async => _source(document, sequence));
    final replacement = session.playbacks.last;
    ready(replacement);
    await flush();
    expect(controller.sentences, hasLength(2));
    old.planGate!.complete(const [NarrationSentence(99, 0, 3)]);
    await flush();
    expect(controller.sentences.first.id, 0);
  });

  test('failure to position the previous sentence releases speech and allows retry', () async {
    final session = FakeNarratorSession(),
        document = Object(),
        sequence = _Sequence()..cursor = 1;
    final controller = NarrationController(open: (_) async => session);
    addTearDown(controller.close);
    await controller.read(document, () async => _source(document, sequence));
    ready(session.playbacks.single);
    await flush();
    controller.navigate(forward: false);
    await flush();
    final previous = session.playbacks.last;
    previous.planFailure = StateError('plan unavailable');
    ready(previous, paused: true);
    await flush();
    expect(controller.snapshot!.phase, NarrationPhase.failed);
    expect(controller.preparing, false);
    expect(previous.disposed, true);
    expect(previous.resumes, 0);
    controller.togglePause();
    await flush();
    expect(session.playbacks, hasLength(3));
    expect(controller.error, isNull);
  });

  test('natural completion traverses the paper and finishes at its forward boundary', () async {
    final session = FakeNarratorSession(),
        document = Object(),
        sequence = _Sequence();
    final controller = NarrationController(open: (_) async => session);
    addTearDown(controller.close);
    await controller.read(document, () async => _source(document, sequence));
    ready(session.playbacks.single);
    session.playbacks.single.completion.complete(NarrationOutcome.completed);
    await flush();
    expect(sequence.cursor, 1);
    ready(session.playbacks.last);
    session.playbacks.last.completion.complete(NarrationOutcome.completed);
    await flush();
    expect(controller.snapshot!.phase, NarrationPhase.completed);
    expect(controller.active, false);
    expect(session.playbacks.every((p) => p.disposed), true);
  });

  for (final ending in ['close', 'replace', 'shutdown', 'range-less state']) {
    test('Stop then $ending preserves the bookmark', () async {
      final session = FakeNarratorSession(),
          document = Object(),
          sequence = _Sequence();
      final saved = <SourceAnchor>[];
      final controller = NarrationController(
        open: (_) async => session,
        onPosition: (_, anchor) => saved.add(anchor),
      );
      addTearDown(controller.close);
      await controller.read(document, () async => _source(document, sequence));
      ready(session.playbacks.single, start: 7);
      if (ending == 'range-less state') {
        session.playbacks.single.emit(NarrationPhase.preparing);
      }
      await controller.stop();
      switch (ending) {
        case 'close':
          await controller.closeDocument(document);
        case 'replace':
          await controller.read(
            Object(),
            () async => NarrationSource(
              documentId: Object(),
              title: 'Other',
              text: 'Other selection.',
            ),
          );
        case 'shutdown':
          await controller.close();
        case 'range-less state':
          await controller.stop();
      }
      expect(saved.map((a) => a.offset), [7]);
      final resumed = sequence.passages.first.sliceFrom(
        sequence.passages.first.offsetOf(saved.last)!,
      );
      expect(resumed.text, 'Second.');
    });
  }

  test('failed initial load is terminal and transport retries it', () async {
    final bad = FakeNarratorSession()
      ..voiceFailure = StateError('catalog failed');
    final good = FakeNarratorSession(),
        document = Object(),
        sequence = _Sequence();
    var opens = 0;
    final controller = NarrationController(
      open: (_) async => opens++ == 0 ? bad : good,
    );
    addTearDown(controller.close);
    await controller.read(document, () async => _source(document, sequence));
    expect(controller.terminal, true);
    expect(controller.active, false);
    expect(controller.snapshot!.phase, NarrationPhase.failed);
    controller.togglePause();
    await flush();
    expect(good.texts, ['First. Second.']);
    expect(controller.error, isNull);
    expect(bad.disposals, 1);
  });

  for (final paused in [false, true]) {
    test(
      'Previous at the first sentence restarts it while ${paused ? 'paused' : 'playing'}',
      () async {
        final session = FakeNarratorSession(),
            document = Object(),
            sequence = _Sequence();
        final controller = NarrationController(open: (_) async => session);
        addTearDown(controller.close);
        await controller.read(
          document,
          () async => _source(document, sequence),
        );
        final playback = session.playbacks.single;
        ready(playback, paused: paused);
        await flush();
        controller.navigate(forward: false);
        await flush();
        expect(playback.cancelled, false);
        expect(controller.terminal, false);
        expect(controller.paused, paused);
        expect(playback.resumes, paused ? 0 : 1);
        expect(playback.lastSentenceId, 0);
        expect(
          playback.commands,
          paused ? ['sentence:0'] : ['pause', 'sentence:0', 'resume'],
        );
        expect(sequence.cursor, 0);
      },
    );

    test(
      'Previous across passages targets the final sentence while ${paused ? 'paused' : 'playing'}',
      () async {
        final session = FakeNarratorSession(),
            document = Object(),
            sequence = _Sequence()..cursor = 1;
        final controller = NarrationController(open: (_) async => session);
        addTearDown(controller.close);
        await controller.read(
          document,
          () async => _source(document, sequence),
        );
        final old = session.playbacks.single;
        ready(old, paused: paused);
        await flush();
        controller.navigate(forward: false);
        await flush();
        final previous = session.playbacks.last;
        expect(old.disposed, true);
        expect(session.texts.last, 'First. Second.');
        expect(session.initialPauses.last, true);
        expect(controller.preparing, true);
        previous.emit(
          NarrationPhase.paused,
        ); // Plan exists, duration is not ready.
        await flush();
        expect(previous.lastSentenceId, isNull);
        expect(previous.resumes, 0);
        ready(previous, paused: true);
        await flush();
        expect(previous.lastSentenceId, 1);
        expect(
          previous.commands,
          paused ? ['sentence:1'] : ['sentence:1', 'resume'],
        );
        expect(controller.preparing, false);
        expect(controller.error, isNull);
      },
    );
  }

  test('Next beyond the final passage completes and releases speech', () async {
    final session = FakeNarratorSession(),
        document = Object(),
        sequence = _Sequence()..cursor = 1;
    final controller = NarrationController(open: (_) async => session);
    addTearDown(controller.close);
    await controller.read(document, () async => _source(document, sequence));
    ready(session.playbacks.single, start: 7);
    await flush();
    controller.navigate(forward: true);
    await flush();
    expect(controller.snapshot!.phase, NarrationPhase.completed);
    expect(session.playbacks.single.disposed, true);
    expect(sequence.cursor, 1);
  });

  test('Stop invalidates a delayed previous-sentence plan', () async {
    final session = FakeNarratorSession(),
        document = Object(),
        sequence = _Sequence()..cursor = 1;
    final controller = NarrationController(open: (_) async => session);
    addTearDown(controller.close);
    await controller.read(document, () async => _source(document, sequence));
    ready(session.playbacks.single);
    await flush();
    controller.navigate(forward: false);
    await flush();
    final playback = session.playbacks.last;
    final plan = playback.planGate = Completer<List<NarrationSentence>?>();
    ready(playback, paused: true);
    await controller.stop();
    plan.complete(playback.sentencePlan);
    await flush();
    expect(playback.lastSentenceId, isNull);
    expect(playback.resumes, 0);
    expect(controller.snapshot!.phase, NarrationPhase.stopped);
  });

  test(
    'native completion racing a backward lookup advances only once',
    () async {
      final session = FakeNarratorSession(),
          document = Object(),
          sequence = _Sequence();
      final controller = NarrationController(open: (_) async => session);
      addTearDown(controller.close);
      await controller.read(document, () async => _source(document, sequence));
      ready(session.playbacks.single);
      await flush();
      sequence.gate = Completer<void>();
      controller.navigate(forward: false);
      session.playbacks.single.completion.complete(NarrationOutcome.completed);
      await flush();
      expect(session.texts, hasLength(1));
      sequence.gate!.complete();
      await flush();
      expect(session.texts, ['First. Second.', 'Third. Fourth.']);
      expect(sequence.cursor, 1);
    },
  );
}
