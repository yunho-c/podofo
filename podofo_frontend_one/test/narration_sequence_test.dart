import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:podofo_one/src/narration/narration_controller.dart';
import 'package:podofo_one/src/narration/narration_sequence.dart';
import 'package:podofo_one/src/narration/narrator.dart';
import 'package:podofo_one/src/narration/source_map.dart';

import 'support/fake_narrator.dart';

class Sequence implements NarrationSequence {
  Completer<NarrationPassage?>? pending;
  int moves = 0, cancellations = 0;
  int preparations = 0;
  bool closed = false;
  @override
  Future<void> prepareNext() async {
    preparations++;
  }

  @override
  Future<NarrationPassage?> move(int direction) async {
    moves++;
    return pending == null
        ? NarrationPassage('Next passage.', [])
        : pending!.future;
  }

  @override
  void cancelPending() {
    cancellations++;
  }

  @override
  void close() {
    closed = true;
  }
}

Future<void> flush() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('closing an old document cannot clear a new request while cleanup is pending', () async {
    final engine = FakeNarratorSession(), a = Object(), b = Object();
    final controller = NarrationController(open: (_) async => engine);
    await controller.read(
      a,
      () async => NarrationSource(documentId: a, title: 'A', text: 'First.'),
    );
    final gate = Completer<void>();
    engine.playbacks.single.disposalGate = gate;
    final closing = controller.closeDocument(a);
    await flush();
    final reading = controller.read(
      b,
      () async => NarrationSource(documentId: b, title: 'B', text: 'Second.'),
    );
    await flush();
    gate.complete();
    await Future.wait([closing, reading]);
    expect(controller.source!.documentId, b);
    expect(engine.texts.last, 'Second.');
    await controller.close();
  });
  test('only native playback completion advances; stop cannot advance a cancelled passage', () async {
    final engine = FakeNarratorSession(),
        sequence = Sequence(),
        document = Object();
    final controller = NarrationController(open: (_) async => engine);
    await controller.read(
      document,
      () async => NarrationSource(
        documentId: document,
        title: 'Paper',
        text: 'First passage.',
        sequence: sequence,
      ),
    );
    engine.playbacks.single.emit(NarrationPhase.completed);
    await flush();
    expect(sequence.moves, 0);
    expect(sequence.preparations, 1);
    engine.playbacks.single.completion.complete(NarrationOutcome.completed);
    await flush();
    expect(engine.texts, ['First passage.', 'Next passage.']);
    expect(sequence.preparations, 2);
    expect(engine.playbacks.first.disposed, true);
    await controller.stop();
    await flush();
    expect(sequence.moves, 1);
    await controller.close();
    expect(sequence.closed, true);
  });

  test('pause during page preparation reaches the new request; Stop rejects a late page', () async {
    final engine = FakeNarratorSession(),
        sequence = Sequence(),
        document = Object();
    final controller = NarrationController(open: (_) async => engine);
    await controller.read(
      document,
      () async => NarrationSource(
        documentId: document,
        title: 'Paper',
        text: 'First.',
        sequence: sequence,
      ),
    );
    sequence.pending = Completer<NarrationPassage?>();
    engine.playbacks.single.completion.complete(NarrationOutcome.completed);
    await flush();
    expect(controller.preparing, true);
    controller.togglePause();
    sequence.pending!.complete(NarrationPassage('Second.', []));
    await flush();
    expect(engine.initialPauses.last, true);
    sequence.pending = Completer<NarrationPassage?>();
    final moving = controller.movePassage(1);
    await flush();
    await controller.stop();
    sequence.pending!.complete(NarrationPassage('Must not play.', []));
    await moving;
    expect(engine.texts, ['First.', 'Second.']);
    await controller.close();
  });

  test(
    'replacing the paper closes its sequence and ignores a late completion',
    () async {
      final engine = FakeNarratorSession(),
          sequence = Sequence(),
          a = Object(),
          b = Object();
      final controller = NarrationController(open: (_) async => engine);
      await controller.read(
        a,
        () async => NarrationSource(
          documentId: a,
          title: 'A',
          text: 'First.',
          sequence: sequence,
        ),
      );
      await controller.read(
        b,
        () async =>
            NarrationSource(documentId: b, title: 'B', text: 'New paper.'),
      );
      await flush();
      expect(sequence.closed, true);
      expect(sequence.moves, 0);
      expect(controller.source!.documentId, b);
      await controller.close();
    },
  );
}
