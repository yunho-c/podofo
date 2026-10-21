import 'package:flutter_test/flutter_test.dart';
import 'package:podofo_one/src/narration/narration_controller.dart';
import 'package:podofo_one/src/narration/narrator.dart';

import 'support/fake_narrator.dart';

Future<void> flush() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test(
    'native sentence navigation and completed replay adopt replacement handles',
    () async {
      final session = FakeNarratorSession(), document = Object();
      final controller = NarrationController(open: (_) async => session);
      await controller.read(
        document,
        () async => NarrationSource(
          documentId: document,
          title: 'Paper',
          text: 'First. Second.',
        ),
      );
      final first = session.playbacks.single;
      first.emit(NarrationPhase.playing);
      await flush();
      controller.navigate(forward: true);
      expect(first.lastForward, true);
      expect(
        first.cancelled,
        false,
      ); // Boundary and in-place navigation preserve cursor ownership.
      first.completion.complete(NarrationOutcome.completed);
      await flush();
      final replay = FakeNarrationPlayback();
      first.navigation = NarrationNavigation(replacement: replay);
      controller.navigate(forward: false);
      await flush();
      replay.emit(NarrationPhase.playing);
      expect(controller.snapshot!.phase, NarrationPhase.playing);
      expect(first.disposed, true);
      await controller.close();
      expect(replay.disposed, true);
    },
  );

  test(
    'speed changes resume at the current sentence and preserve paused intent',
    () async {
      final session = FakeNarratorSession(), document = Object();
      final controller = NarrationController(open: (_) async => session);
      await controller.read(
        document,
        () async => NarrationSource(
          documentId: document,
          title: 'Paper',
          text: 'First. Second.',
        ),
      );
      session.playbacks.single.events.add(
        const NarrationSnapshot(
          phase: NarrationPhase.paused,
          start: 7,
          end: 14,
        ),
      );
      await controller.configure(const NarrationSettings(speed: 1.3));
      expect(session.texts, ['First. Second.', 'Second.']);
      expect(session.requests.last.speed, 1.3);
      expect(session.initialPauses.last, true);
      expect(session.playbacks.first.disposed, true);
      await controller.close();
    },
  );

  test(
    'timeline seeks use total estimate; completion retains its source position',
    () async {
      final session = FakeNarratorSession(), document = Object();
      final controller = NarrationController(open: (_) async => session);
      await controller.read(
        document,
        () async => NarrationSource(
          documentId: document,
          title: 'Paper',
          text: 'First. Second.',
        ),
      );
      final speech = session.playbacks.single;
      speech.events.add(
        const NarrationSnapshot(
          phase: NarrationPhase.playing,
          start: 7,
          end: 14,
          positionFrames: 200,
          estimatedFrames: 1000,
        ),
      );
      controller.seek(800);
      expect(speech.lastSeek, 800);
      speech.completion.complete(NarrationOutcome.completed);
      await flush();
      expect(controller.snapshot!.start, 7);
      expect(controller.snapshot!.estimatedFrames, 1000);
      await controller.close();
    },
  );
}
