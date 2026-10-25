import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
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
      if (defaultTargetPlatform == TargetPlatform.macOS) {
        expect(find.text('File'), findsNothing);
        final menuBar = tester.widget<PlatformMenuBar>(
          find.byType(PlatformMenuBar),
        );
        final menus = menuBar.menus.cast<PlatformMenu>();
        expect(menus.map((menu) => menu.label), ['PoDoFo', 'File']);
        final fileItems = menus.last.menus;
        expect(fileItems.map((item) => item.label), [
          'Open PDF',
          'Save',
          'Save As…',
          'Close tab',
        ]);
        expect(fileItems.first.onSelected, isNotNull);
        expect(
          fileItems.skip(1).every((item) => item.onSelected == null),
          isTrue,
        );
      } else {
        expect(find.text('File'), findsOneWidget);
        expect(find.byType(PlatformMenuBar), findsNothing);
      }
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.linux,
    }),
  );
}
