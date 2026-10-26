import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:podofo_one/src/analysis/analysis_controller.dart';
import 'package:podofo_one/src/analysis/analysis_store.dart';
import 'package:podofo_one/src/providers/analysis_provider.dart';
import 'package:podofo_one/src/widgets/components/layout_analysis_controls.dart';

void main() {
  testWidgets(
    'cache failure offers explicit retry without background retries',
    (tester) async {
      var attempts = 0;
      final controller = AnalysisController(
        store: AnalysisStore(Directory.systemTemp),
      );
      final container = ProviderContainer(
        overrides: [
          equationControllerProvider.overrideWithValue(null),
          analysisControllerProvider.overrideWith((ref) async {
            if (++attempts == 1) throw StateError('cache unavailable');
            return controller;
          }),
        ],
      );
      try {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const ShadcnApp(
              home: SizedBox(width: 300, child: LayoutAnalysisControls()),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(seconds: 30));
        expect(attempts, 1);
        expect(find.text('Retry analysis cache'), findsOneWidget);
        await tester.tap(find.text('Retry analysis cache'));
        await tester.pump();
        await tester.pump();
        expect(attempts, 2);
        expect(find.text('Open layout model…'), findsNothing);
        await tester.tap(
          find.descendant(
            of: find.byType(CollapsibleTrigger),
            matching: find.byType(GhostButton),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Open layout model…'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
        await controller.close();
        controller.dispose();
      }
    },
    skip: !Platform.isMacOS,
  );
}
