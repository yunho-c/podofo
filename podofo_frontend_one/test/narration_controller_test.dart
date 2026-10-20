import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:podofo_one/src/narration/narration_controller.dart';
import 'package:podofo_one/src/narration/narrator.dart';

import 'support/fake_narrator.dart';

void main() {
  final owner = Object();
  NarrationSource source(String text, {Object? document}) => NarrationSource(
    documentId: document ?? owner,
    title: 'Paper',
    text: text,
  );

  test(
    'one engine serves sequential selections; native pause preserves speech',
    () async {
      final session = FakeNarratorSession();
      var opens = 0;
      final controller = NarrationController(
        open: (_) async {
          opens++;
          return session;
        },
      );
      addTearDown(controller.close);
      await controller.read(
        owner,
        () async => source('First sentence. Second sentence.'),
      );
      final first = session.playbacks.single;
      first.emit(NarrationPhase.playing);
      controller.togglePause();
      expect(first.pauses, 1);
      expect(first.cancelled, false);
      first.emit(NarrationPhase.paused);
      controller.togglePause();
      expect(first.resumes, 1);
      expect(session.playbacks, hasLength(1));
      await controller.read(owner, () async => source('Another selection.'));
      expect(opens, 1);
      expect(first.disposed, true);
      expect(session.texts.last, 'Another selection.');
      await controller.close();
      expect(session.disposals, 1);
      expect(session.playbacks.every((p) => p.disposed), true);
    },
  );

  test('Stop during model loading prevents late audio, and engine remains reusable', () async {
    final loading = Completer<NarratorSession>();
    final session = FakeNarratorSession();
    final controller = NarrationController(open: (_) => loading.future);
    addTearDown(controller.close);
    final read = controller.read(owner, () async => source('Old request.'));
    await pumpEventQueue();
    await controller.stop();
    loading.complete(session);
    await read;
    expect(session.playbacks, isEmpty);
    expect(controller.active, false);
    await controller.read(owner, () async => source('New request.'));
    expect(session.texts, ['New request.']);
  });

  test('latest selection wins while engine is opening', () async {
    final loading = Completer<NarratorSession>();
    final session = FakeNarratorSession();
    var opens = 0;
    final controller = NarrationController(
      open: (_) {
        opens++;
        return loading.future;
      },
    );
    addTearDown(controller.close);
    final first = controller.read(owner, () async => source('First.'));
    await pumpEventQueue();
    final second = controller.read(owner, () async => source('Second.'));
    await pumpEventQueue();
    loading.complete(session);
    await Future.wait([first, second]);
    expect(opens, 1);
    expect(session.texts, ['Second.']);
  });

  test(
    'closing a document during selection extraction prevents loading',
    () async {
      final extraction = Completer<NarrationSource>();
      var opens = 0;
      final controller = NarrationController(
        open: (_) async {
          opens++;
          return FakeNarratorSession();
        },
      );
      addTearDown(controller.close);
      final read = controller.read(owner, () => extraction.future);
      await controller.closeDocument(owner);
      extraction.complete(source('Too late.'));
      await read;
      expect(opens, 0);
      expect(controller.source, isNull);
      expect(controller.preparing, false);
    },
  );

  test('closing another document leaves active speech alone', () async {
    final session = FakeNarratorSession();
    final controller = NarrationController(open: (_) async => session);
    addTearDown(controller.close);
    await controller.read(owner, () async => source('Keep reading.'));
    await controller.closeDocument(Object());
    expect(session.playbacks.single.cancelled, false);
  });

  test(
    'application close joins a late model and disposes it exactly once',
    () async {
      final loading = Completer<NarratorSession>();
      final session = FakeNarratorSession();
      final controller = NarrationController(open: (_) => loading.future);
      final read = controller.read(owner, () async => source('Never play.'));
      await pumpEventQueue();
      final close = controller.close();
      loading.complete(session);
      await Future.wait([read, close]);
      await controller.close();
      expect(session.playbacks, isEmpty);
      expect(session.disposals, 1);
      expect(controller.error, isNull);
    },
  );

  test(
    'pause requested during preparation starts native speech paused',
    () async {
      final loading = Completer<NarratorSession>();
      final session = FakeNarratorSession();
      final controller = NarrationController(open: (_) => loading.future);
      addTearDown(controller.close);
      final read = controller.read(owner, () async => source('Wait here.'));
      await pumpEventQueue();
      controller.togglePause();
      loading.complete(session);
      await read;
      expect(session.initialPauses, [true]);
    },
  );

  test('replaced completion cannot change the current presentation', () async {
    final session = FakeNarratorSession();
    final controller = NarrationController(open: (_) async => session);
    addTearDown(controller.close);
    await controller.read(owner, () async => source('First.'));
    final first = session.playbacks.single;
    await controller.read(owner, () async => source('Second.'));
    session.playbacks.last.emit(NarrationPhase.playing);
    await pumpEventQueue();
    expect(first.cancelled, true);
    expect(controller.snapshot?.phase, NarrationPhase.playing);
    expect(controller.source?.text, 'Second.');
    expect(controller.error, isNull);
  });

  test(
    'model failure releases the engine and permits an explicit retry',
    () async {
      final bad = FakeNarratorSession()
        ..voiceFailure = StateError('corrupt catalog');
      final good = FakeNarratorSession();
      var opens = 0;
      final controller = NarrationController(
        open: (_) async => opens++ == 0 ? bad : good,
      );
      addTearDown(controller.close);
      await controller.read(owner, () async => source('Read.'));
      expect(controller.error, contains('corrupt catalog'));
      expect(bad.disposals, 1);
      await controller.read(owner, () async => source('Try again.'));
      expect(good.texts, ['Try again.']);
      expect(controller.error, isNull);
    },
  );

  test(
    'UTF-8 limit is checked before opening a model, without truncation',
    () async {
      var opens = 0;
      final controller = NarrationController(
        open: (_) async {
          opens++;
          return FakeNarratorSession();
        },
      );
      addTearDown(controller.close);
      await controller.read(owner, () async => source('한' * 22000));
      expect(opens, 0);
      expect(controller.error, contains('too long'));
    },
  );

  test(
    'unsupported targets never try to load native model resources',
    () async {
      var opens = 0;
      final controller = NarrationController(
        open: (_) async {
          opens++;
          return FakeNarratorSession();
        },
        unavailableReason: 'Unavailable on this platform.',
      );
      addTearDown(controller.close);
      await controller.read(owner, () async => source('Read.'));
      expect(opens, 0);
      expect(controller.error, 'Unavailable on this platform.');
    },
  );
}
