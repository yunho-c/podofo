import 'dart:io';

import 'package:podoco/podoco.dart';
import 'package:test/test.dart';

void main() {
  test('math limits and explicit preference roundtrip', () {
    expect(() => MathLimits(queuedRequests: 0), throwsRangeError);
    expect(() => MathLimits(inputBytes: 65537), throwsRangeError);
    expect(() => MathLimits(depth: 65), throwsRangeError);
    final options = MathSpeechOptions(
      language: 'es',
      speechStyle: 'SimpleSpeak',
      verbosity: MathVerbosity.verbose,
      decimalSeparators: ',',
      blockSeparators: '.',
    );
    expect(
      MathSpeechOptions.fromJson(options.toJson()).toJson(),
      options.toJson(),
    );
  });
  test('optional module is checked before rule or symbol access', () async {
    if (mathAvailable) return;
    await expectLater(
      MathRules.verify('unused'),
      throwsA(
        isA<PodocoException>().having(
          (e) => e.code,
          'code',
          'unsupported_capability',
        ),
      ),
    );
  });
  final path = Platform.environment['PODOCO_M7_RULES'];
  group(
    'native math',
    () {
      late MathRules rules;
      late MathProcessor processor;
      const input = MathInput.latex(
        r'\frac{x+1}{2}',
        displayKind: FormulaDisplayKind.inline,
      );
      const english = MathSpeechOptions(
        language: 'en',
        speechStyle: 'ClearSpeak',
      );
      const spanish = MathSpeechOptions(
        language: 'es',
        speechStyle: 'SimpleSpeak',
      );
      setUp(() async {
        expect(mathAvailable, isTrue);
        rules = await MathRules.verify(path!);
        processor = await MathProcessor.open(rules);
      });
      tearDown(() async {
        await processor.dispose();
        expect(nativeLiveHandles, 0);
      });
      test(
        'strict source preservation, MathML, owned errors and healthy reuse',
        () async {
          final mathml = await processor.toMathml(input);
          expect(mathml.mathml, contains('<mfrac>'));
          expect(mathml.provenance.rulesManifestSha256, rules.manifestSha256);
          final speech = await processor.toSpeech(input, english);
          expect(speech.text, isNotEmpty);
          expect(
            (await processor.toSpeech(
              MathInput.mathml(
                mathml.mathml,
                displayKind: FormulaDisplayKind.inline,
              ),
              english,
            )).text,
            speech.text,
          );
          const unsupported = MathInput.latex(
            r'\unknown{x}',
            displayKind: FormulaDisplayKind.inline,
          );
          await expectLater(
            processor.toSpeech(unsupported, english),
            throwsA(
              isA<PodocoException>().having(
                (e) => e.code,
                'code',
                'conversion',
              ),
            ),
          );
          expect(unsupported.text, r'\unknown{x}');
          await expectLater(
            processor.toSpeech(
              input,
              const MathSpeechOptions(
                language: 'ko',
                speechStyle: 'ClearSpeak',
              ),
            ),
            throwsA(
              isA<PodocoException>().having(
                (e) => e.code,
                'code',
                'unsupported_capability',
              ),
            ),
          );
          expect((await processor.toSpeech(input, english)).text, speech.text);
        },
      );
      test(
        'multiple processors and interleaved language snapshots stay isolated',
        () async {
          final second = await MathProcessor.open(rules);
          try {
            final en = (await processor.toSpeech(input, english)).text;
            final es = (await second.toSpeech(input, spanish)).text;
            expect(en, isNot(es));
            for (var i = 0; i < 3; i++) {
              final values = await Future.wait([
                processor.toSpeech(input, spanish),
                second.toSpeech(input, english),
              ]);
              expect(values.map((v) => v.text), [es, en]);
            }
            await processor.dispose();
            expect((await second.toSpeech(input, spanish)).text, es);
          } finally {
            await second.dispose();
          }
        },
      );
      test(
        'bounded admission, disposal drains pending calls and rejects reuse',
        () async {
          await processor.dispose();
          processor = await MathProcessor.open(
            rules,
            limits: MathLimits(queuedRequests: 1),
          );
          final first = processor.toSpeech(input, english);
          final second = processor.toSpeech(input, spanish);
          await expectLater(
            processor.toSpeech(input, english),
            throwsA(
              isA<PodocoException>().having(
                (e) => e.code,
                'code',
                'limit_exceeded',
              ),
            ),
          );
          // Close can race bridge admission: already active succeeds; queued work is
          // cancelled; not-yet-admitted bridge calls see the closed worker.
          final settled = [first, second]
              .map(
                (f) => f.then<void>(
                  (_) {},
                  onError: (Object e) {
                    expect(
                      e,
                      isA<PodocoException>().having(
                        (e) => e.code,
                        'code',
                        isIn(['cancelled', 'invalid_input']),
                      ),
                    );
                  },
                ),
              )
              .toList();
          await processor.dispose();
          await Future.wait(settled);
          await processor.dispose();
          await expectLater(processor.toMathml(input), throwsStateError);
        },
      );
    },
    skip: path == null
        ? 'Requires explicit PODOCO_M7_RULES and math build'
        : false,
  );
}
