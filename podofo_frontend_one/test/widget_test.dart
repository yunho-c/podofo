import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:podofo_one/main.dart';
import 'package:podofo_one/src/providers/document_provider.dart';
import 'package:podofo_one/src/providers/user_state_provider.dart';

class _TestUserState extends UserStateNotifier {
  @override
  UserState build() => UserState()
    ..highlightColor = '#66ffeb3b'
    ..highlightColorPalette = ['#66ffeb3b'];
}

void main() {
  testWidgets(
    'empty app renders its document controls without native storage',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            initialDocumentsProvider.overrideWith((ref) async => {}),
            userStateNotifierProvider.overrideWith(_TestUserState.new),
          ],
          child: const MyApp(),
        ),
      );
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 5),
      );
      expect(
        find.text('Press the plus icon to pick a PDF file.'),
        findsOneWidget,
      );
      expect(find.text('File'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
