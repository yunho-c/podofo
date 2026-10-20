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
