import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
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

      Map<dynamic, dynamic>? nativeMenus;
      const menuChannel = OptionalMethodChannel('flutter/menu');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        menuChannel,
        (call) async {
          if (call.method == 'Menu.setMenus') {
            nativeMenus = call.arguments as Map;
          }
          return null;
        },
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          menuChannel,
          null,
        );
      });

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
        expect(menus.map((menu) => menu.label), [
          'PoDoFo',
          'File',
          'Edit',
          'View',
          'Window',
        ]);
        final fileItems = menus
            .firstWhere((menu) => menu.label == 'File')
            .menus;
        final editItems = menus
            .firstWhere((menu) => menu.label == 'Edit')
            .menus;
        expect(editItems.map((item) => item.label), ['Undo', 'Redo']);
        expect(editItems.every((item) => item.onSelected == null), isTrue);
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

        // Native window commands must reach the macOS menu plugin, even with
        // no document open. AppKit supplies their shortcuts and action targets.
        expect(nativeMenus, isNotNull);
        final nativeTopLevel = (nativeMenus!['0'] as List).cast<Map>();
        for (final entry in {
          'View': [PlatformProvidedMenuItemType.toggleFullScreen],
          'Window': [
            PlatformProvidedMenuItemType.minimizeWindow,
            PlatformProvidedMenuItemType.zoomWindow,
            PlatformProvidedMenuItemType.arrangeWindowsInFront,
          ],
        }.entries) {
          final nativeMenu = nativeTopLevel.firstWhere(
            (menu) => menu['label'] == entry.key,
          );
          final items = (nativeMenu['children'] as List).cast<Map>().where(
            (item) => item.containsKey('platformProvidedMenu'),
          );
          expect(
            items.map((item) => item['platformProvidedMenu']),
            entry.value.map((type) => type.index),
          );
          expect(items.every((item) => item['enabled'] == true), isTrue);
        }
      } else {
        expect(find.text('File'), findsOneWidget);
        expect(find.text('Edit'), findsOneWidget);
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
