// Opt-in real-PDF warm-engine diagnostic, not a latency acceptance test.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mlsr/mlsr.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:podofo_one/src/narration/duration_profile.dart';
import 'package:podofo_one/src/narration/mlsr_narrator.dart';
import 'package:podofo_one/src/narration/narrator.dart';
import 'package:podofo_one/src/narration/paper_plan.dart';
import 'package:podofo_one/src/narration/paper_sequence.dart';
import 'package:podofo_one/src/services/pdf_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'profile warm document duration and export matched text corpus',
    () async {
      final pdf = File(Platform.environment['PROFILE_PDF']!).absolute;
      final output = Directory(Platform.environment['PROFILE_OUTPUT']!)
          .absolute;
      await output.create(recursive: true);
      Pdfrx.pdfiumModulePath = File(
        Platform.environment['PDFIUM_PATH'] ??
            'build/native_assets/macos/libpdfium.dylib',
      ).absolute.path;
      await pdfrxInitialize(tmpPath: output.path);
      final document = await PdfSession.open(pdf.path);
      Tts? tts;
      PaperSequence? paper;
      final report = <String, Object?>{
        'passed': false,
        'pdf': pdf.path,
        'pdf_sha256': sha256.convert(pdf.readAsBytesSync()).toString(),
        'boundary': 'warm engine; no foreground speech; Flutter test runner, not release UI',
        'runs': <Map<String, Object?>>[],
      };
      try {
        final load = Stopwatch()..start();
        tts = await Tts.open(
          manifest:
              '.mlsr/sdk/model-manifests/supertonic3-coreml-fp16-voices.yaml',
          bundle: '.mlsr/model_assets/models/supertonic3-coreml-fp16-t384-voices-v1',
          options: const TtsOptions(output: OutputMode.headless),
        );
        report['load_ms_excluded'] = load.elapsedMicroseconds / 1000;
        final warmup = tts.planDuration(
          'The results agree with the prediction.',
        );
        await warmup.done;
        await warmup.timeline();
        await warmup.dispose();
        for (var repetition = 0; repetition < 3; repetition++) {
          final profile = DurationProfile();
          paper = PaperSequence(
            document,
            const PaperReadOptions(),
            profile: profile,
          );
          final narrator = MlsrNarrator.fromTts(tts, profile: profile);
          final timer = Stopwatch()..start();
          paper.configureTiming(
            narrator,
            const NarrationSettings(voice: 'supertonic3:M1'),
          );
          await paper.timingIdle.timeout(const Duration(minutes: 3));
          final total = timer.elapsedMicroseconds;
          final snapshot = paper.timeline.snapshot;
          (report['runs'] as List).add({
            'repetition': repetition,
            'total_us': total,
            'passages': snapshot.passageCount,
            'planned': snapshot.plannedPassages,
            'failed': snapshot.failedPassages,
            'failure_messages': [
              for (final p in paper.index.snapshot.passages)
                if (paper.timeline.failure(p.id) != null)
                  paper.timeline.failure(p.id),
            ],
            'unresolved_pages': snapshot.unresolvedPages,
            'extractions': paper.planner.extractionCount,
            'trace': profile.toJson(),
          });
          final snapshotStart = profile.begin();
          for (var i = 0; i < 100; i++) {
            paper.timeline.snapshot;
          }
          profile.end('snapshot_100_reads', snapshotStart);
          // Real scientific PDFs can contain unsupported symbol-only passages.
          // Report those separately; require every passage to reach a terminal result.
          expect(snapshot.unresolvedPages, 0);
          expect(
            snapshot.plannedPassages + snapshot.failedPassages,
            snapshot.passageCount,
          );
          expect(profile.dropped, 0);
          stdout.writeln(
            'APP_PROFILE repetition=$repetition passages=${snapshot.passageCount} ms=${total / 1000}',
          );
          if (repetition == 0) {
            final units = <String>[];
            for (
              var page = 1;
              page <= paper.index.scopeEndPage && units.length < 24;
              page++
            ) {
              final plan = await paper.planner.plan(page, paper.options);
              for (final passage in plan.passages) {
                for (final sentence in passage.text.split(
                  RegExp(r'(?<=[.!?])\s+'),
                )) {
                  final text = sentence.replaceAll(RegExp(r'\s+'), ' ').trim();
                  if (text.length >= 35 &&
                      text.length <= 220 &&
                      RegExp(r'[.!?]$').hasMatch(text) &&
                      units.length < 24) {
                    units.add(text);
                  }
                }
              }
            }
            expect(units, hasLength(24));
            File('${output.path}/corpus.json').writeAsStringSync(
              jsonEncode({
                'pdf_sha256': report['pdf_sha256'],
                'selection': 'first 24 extracted sentences of 35..220 UTF-16 units; whitespace normalized',
                'canonical_sha256': sha256
                    .convert(utf8.encode(units.join('\n')))
                    .toString(),
                'units': units,
              }),
            );
          }
          paper.close();
          paper = null;
        }
        report['passed'] = true;
      } finally {
        paper?.close();
        await tts?.dispose();
        await document.close();
        await PdfrxEntryFunctions.instance.stopBackgroundWorker();
        File('${output.path}/app.json').writeAsStringSync(
          '${const JsonEncoder.withIndent('  ').convert(report)}\n',
        );
      }
    },
    skip: Platform.environment['PROFILE_PDF'] == null,
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
