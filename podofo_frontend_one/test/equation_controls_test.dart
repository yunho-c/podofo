import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:podofo_one/src/analysis/equation_controller.dart';
import 'package:podofo_one/src/analysis/pdf_analysis_source.dart';
import 'package:podofo_one/src/narration/narration_controller.dart';
import 'package:podofo_one/src/providers/analysis_provider.dart';
import 'package:podofo_one/src/services/pdf_session.dart';
import 'package:podofo_one/src/widgets/components/equation_controls.dart';

import 'equation_controller_test.dart' show FakeMath, PublishingAnalysis;
import 'fixtures/analysis_fixture.dart';
import 'fixtures/pdf_fixture.dart';
import 'support/fake_narrator.dart';

void main() {
  testWidgets(
    'pending formulas become actionable and Copy survives speech failure',
    (tester) async {
      final temporary = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('equation-controls-'),
      ))!;
      await tester.runAsync(() => pdfrxInitialize(tmpPath: temporary.path));
      final pdf = File('${temporary.path}/page.pdf')
        ..writeAsBytesSync(pdfFixture());
      final document = (await tester.runAsync(
        () => PdfSession.open(pdf.path),
      ))!;
      final analysis = PublishingAnalysis(temporary)..select(document, 0);
      final math = FakeMath()..failure = StateError('Unsupported expression');
      final audio = FakeNarratorSession();
      final narration = NarrationController(open: (_) async => audio);
      final copied = <String>[];
      final equations = EquationController(
        analysis: analysis,
        narration: narration,
        open: (_) async => math,
        copy: (text) async => copied.add(text),
      );
      await equations.configureRules('rules');
      analysis.publish(formulaFixture(analysisDocumentRef(document)));
      final container = ProviderContainer(
        overrides: [equationControllerProvider.overrideWithValue(equations)],
      );
      try {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const ShadcnApp(
              home: Center(
                child: SizedBox(
                  width: 350,
                  child: SingleChildScrollView(child: EquationControls()),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Equation 1 · pending'));
        await tester.pump();
        expect(find.text('Recognition is still pending.'), findsOneWidget);
        expect(find.text('Copy LaTeX'), findsNothing);
        analysis.publish(
          formulaFixture(analysisDocumentRef(document), stage: 1),
        );
        await tester.pump();
        expect(find.text('Equation 1 · ready'), findsOneWidget);
        await tester.tap(find.text('Copy LaTeX'));
        await tester.pump();
        expect(copied, [r'\frac{x+1}{2}']);
        await tester.tap(find.text('Listen to equation'));
        await tester.pump();
        expect(find.textContaining('Unsupported expression'), findsOneWidget);
        expect(audio.texts, isEmpty);
        await tester.tap(find.text('Copy LaTeX'));
        await tester.pump();
        expect(copied, [r'\frac{x+1}{2}', r'\frac{x+1}{2}']);
        analysis.select(null, 0);
        await tester.pump();
        expect(find.text('Copy LaTeX'), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
        await tester.runAsync(() async {
          await equations.close();
          equations.dispose();
          await narration.close();
          narration.dispose();
          await analysis.close();
          analysis.dispose();
          await document.close();
          await PdfrxEntryFunctions.instance.stopBackgroundWorker();
          await temporary.delete(recursive: true);
        });
      }
    },
  );
}
