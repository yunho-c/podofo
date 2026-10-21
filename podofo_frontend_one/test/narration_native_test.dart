import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// Test-only registry accounting. It does not measure native memory usage.
// ignore: implementation_imports
import 'package:mlsr/src/bindings.g.dart' as native;
import 'package:mlsr_app_models/app_models.dart';
import 'package:podofo_one/src/narration/mlsr_narrator.dart';
import 'package:podofo_one/src/narration/narration_controller.dart';
import 'package:podofo_one/src/narration/narrator.dart';
import 'package:podofo_one/src/narration/narration_sequence.dart';
import 'package:podofo_one/src/narration/source_map.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'real prepared model, pause/resume, replacement and native cleanup',
    () async {
      const channel = MethodChannel('dev.mlsr.flutter/models');
      final resources = Directory(
        '.mlsr/model_assets/${AppModels.supertonic3.assetPath}',
      ).absolute;
      // The Flutter test runner has no macOS plugin registrar. Only resource path
      // discovery is substituted; model verification, synthesis and output are real.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            return switch (call.method) {
              'platform' => 'macos-arm64',
              'locate' => resources.path,
              _ => throw StateError(
                'Unexpected resource operation: ${call.method}',
              ),
            };
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final baseline = native.mlsr_live_handles();
      var opens = 0;
      final controller = NarrationController(
        open: (progress) {
          opens++;
          return MlsrNarrator.open(progress, volume: 0);
        },
      );
      final owner = Object();
      NarrationSource source(String text) => NarrationSource(
        documentId: owner,
        title: 'Native qualification',
        text: text,
      );
      Future<void> until(bool Function() condition, String stage) async {
        final deadline = DateTime.now().add(const Duration(seconds: 60));
        while (!condition()) {
          if (controller.error != null) fail('$stage: ${controller.error}');
          if (DateTime.now().isAfter(deadline)) fail('Timed out: $stage');
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      }

      try {
        await controller.read(
          owner,
          () async => source(
            'This paper introduces a method for studying the motion of particles. '
            'The results are compared with measurements from an independent experiment.',
          ),
        );
        expect(controller.error, isNull);
        expect(controller.voices, hasLength(10));
        await until(
          () => (controller.snapshot?.positionFrames ?? 0) > 4096,
          'first audio',
        );
        controller.togglePause();
        await until(
          () => controller.snapshot?.phase == NarrationPhase.paused,
          'pause',
        );
        final paused = controller.snapshot!.positionFrames;
        await Future<void>.delayed(const Duration(milliseconds: 250));
        expect(controller.snapshot!.positionFrames, paused);
        controller.togglePause();
        await until(
          () => (controller.snapshot?.positionFrames ?? 0) > paused,
          'resume',
        );
        await controller.read(
          owner,
          () async => source('The result is reproducible.'),
        );
        await until(
          () => controller.snapshot?.phase == NarrationPhase.completed,
          'replacement drain',
        );
        expect(opens, 1);
        // Cross-passage Previous starts paused and selects the final native
        // sentence before any presented audio can begin at the passage start.
        for (final paused in [true, false]) {
          final sequence = _NativeSequence();
          await controller.read(
            owner,
            () async => NarrationSource(
              documentId: owner,
              title: 'Backward navigation',
              text: sequence.passages.last.text,
              passage: sequence.passages.last,
              sequence: sequence,
            ),
          );
          await until(
            () =>
                controller.sentences.isNotEmpty &&
                controller.snapshot?.sentenceId == 0,
            'current sentence plan',
          );
          if (paused) {
            controller.togglePause();
            await until(
              () => controller.snapshot?.phase == NarrationPhase.paused,
              'pause before previous',
            );
          }
          var heardOpening = false;
          void watch() {
            final state = controller.snapshot;
            if (controller.source?.text == sequence.passages.first.text &&
                state?.phase == NarrationPhase.playing &&
                (state?.positionFrames ?? 0) > 0 &&
                state?.sentenceId == 0) {
              heardOpening = true;
            }
          }

          controller.addListener(watch);
          try {
            controller.navigate(forward: false);
            await until(
              () =>
                  !controller.preparing &&
                  controller.source?.text == sequence.passages.first.text &&
                  controller.snapshot?.sentenceId == 1,
              'previous passage final sentence',
            );
            expect(heardOpening, false);
            if (paused) {
              expect(controller.snapshot!.phase, NarrationPhase.paused);
              final frame = controller.snapshot!.positionFrames;
              await Future<void>.delayed(const Duration(milliseconds: 200));
              expect(controller.snapshot!.positionFrames, frame);
            } else {
              await until(
                () => controller.snapshot?.phase == NarrationPhase.playing,
                'previous sentence playing',
              );
            }
          } finally {
            controller.removeListener(watch);
            await controller.stop();
          }
        }
        await controller.read(
          owner,
          () async => source('This request should stop promptly.'),
        );
        await controller.stop();
        expect(controller.active, false);
        expect(controller.error, isNull);
      } finally {
        await controller.close();
      }
      expect(native.mlsr_live_handles(), baseline);
    },
    skip: Platform.environment['PODOFO_TEST_MLSR'] != '1',
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

class _NativeSequence implements NarrationSequence {
  final passages = [
    NarrationPassage(
      'This opening sentence must not play. '
      'The final sentence is the intended destination for backward navigation.',
      [],
    ),
    NarrationPassage(
      'The next passage begins with a long sentence about the '
      'experimental results and their reproducibility in independent studies.',
      [],
    ),
  ];
  int cursor = 1;
  @override
  Future<NarrationPassage?> move(int direction) async {
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
