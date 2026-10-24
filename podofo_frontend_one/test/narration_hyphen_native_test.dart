import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mlsr_app_models/app_models.dart';
import 'package:mlsr_flutter/mlsr_flutter.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:podofo_one/src/narration/paper_plan.dart';
import 'package:podofo_one/src/narration/pdf_text_repository.dart';
import 'package:podofo_one/src/services/pdf_session.dart';

import 'fixtures/narration_pdf_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'real PDF joined word reaches MLSR model input and produces audio',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'podofo-hyphen-native-',
      );
      addTearDown(() async {
        await PdfrxEntryFunctions.instance.stopBackgroundWorker();
        await directory.delete(recursive: true);
      });
      await pdfrxInitialize(tmpPath: directory.path);
      final file = File('${directory.path}/hyphen.pdf')
        ..writeAsBytesSync(discretionaryHyphenPdfFixture());
      final session = await PdfSession.open(file.path);
      addTearDown(session.close);
      final page = (await PdfTextRepository(session).extract(1)).text;
      expect(page.text, contains('inter\u0002national'));
      final passage = PaperPlanner.plan(
        page,
        const PaperReadOptions(skipRunningMatter: false),
      ).passages.single;
      const channel = MethodChannel('dev.mlsr.flutter/models');
      final resources = Directory(
        '.mlsr/model_assets/${AppModels.supertonic3.assetPath}',
      ).absolute;
      // Only plugin resource discovery is substituted in the Flutter test runner.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (call) async => switch (call.method) {
              'platform' => 'macos-arm64',
              'locate' => resources.path,
              _ => throw StateError(
                'Unexpected resource operation: ${call.method}',
              ),
            },
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final tts = await FlutterMlsr.openTts(model: AppModels.supertonic3);
      addTearDown(tts.dispose);
      final job = tts.synthesize(
        passage.text,
        options: const RequestOptions(voice: 'supertonic3:M1', locale: 'en'),
      );
      addTearDown(job.dispose);
      final audio = await tts.collect(job);
      expect((await job.done).kind, OutcomeKind.completed);
      final plan = (await job.plan())!;
      expect(plan.original, passage.text);
      expect(plan.segments.single.original, passage.text);
      expect(
        plan.segments.single.normalized,
        '<en>We study international cooperation with well-known methods.</en>',
      );
      for (final segment in plan.segments) {
        expect(
          passage.text.substring(segment.utf16.start, segment.utf16.end),
          segment.original,
        );
        expect(
          utf8.decode(
            utf8
                .encode(passage.text)
                .sublist(segment.utf8.start, segment.utf8.end),
          ),
          segment.original,
        );
        expect(
          passage.rectangles(1, segment.utf16.start, segment.utf16.end),
          isNotEmpty,
        );
      }
      expect(audio.frames, greaterThan(0));
      expect(audio.samples.every((sample) => sample.isFinite), true);
      expect(audio.samples.any((sample) => sample.abs() > 0.001), true);
      // Unique output paths keep repeated runs from overwriting listening evidence.
      final output = await Directory('build/test-artifacts')
          .create(recursive: true);
      final wav = await audio.writeWav(
        '${output.path}/hyphen-${DateTime.now().microsecondsSinceEpoch}.wav',
      );
      // ignore: avoid_print
      print('Listening sample: ${wav.path} (${audio.frames} frames)');
    },
    skip: Platform.environment['PODOFO_TEST_MLSR'] != '1',
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
