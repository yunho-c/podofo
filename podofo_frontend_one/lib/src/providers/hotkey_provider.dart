import 'dart:io' show Platform;
import 'package:flutter/services.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hotkey_manager/hotkey_manager.dart';

import 'package:podofo_one/src/data/pane_data.dart';
import 'package:podofo_one/src/providers/providers.dart';
import 'package:podofo_one/src/providers/tab_provider.dart';
import 'package:podofo_one/src/providers/user_state_provider.dart';

// TODO: Data-ify this, instead of hard-coding.
// TODO: Persistence (serialization), editor visualization, editing
// TODO: Real-time visualization for the entire app (toggleable via 'More')
final hotkeyProvider = Provider<void>((ref) {
  final Map<int, PhysicalKeyboardKey> topRowNumberKeys = {
    1: PhysicalKeyboardKey.digit1,
    2: PhysicalKeyboardKey.digit2,
    3: PhysicalKeyboardKey.digit3,
    4: PhysicalKeyboardKey.digit4,
    5: PhysicalKeyboardKey.digit5,
    6: PhysicalKeyboardKey.digit6,
    7: PhysicalKeyboardKey.digit7,
    8: PhysicalKeyboardKey.digit8,
    9: PhysicalKeyboardKey.digit9,
    0: PhysicalKeyboardKey.digit0,
  };

  hotKeyManager.register(
    HotKey(
      key: PhysicalKeyboardKey.keyP,
      modifiers: [HotKeyModifier.control],
      scope: HotKeyScope.inapp,
    ),
    keyDownHandler: (_) {
      ref.read(commandPaletteProvider.notifier).update((state) => !state);
    },
  );
  hotKeyManager.register(
    HotKey(
      key: PhysicalKeyboardKey.keyH,
      modifiers: [],
      scope: HotKeyScope.inapp,
    ),
    keyDownHandler: (_) {
      final currentHighlight = ref.read(userStateNotifierProvider).highlight;
      ref
          .read(userStateNotifierProvider.notifier)
          .setHighlight(!currentHighlight);
    },
  );
  hotKeyManager.register(
    HotKey(
      key: PhysicalKeyboardKey.keyB,
      modifiers: [
        Platform.isMacOS ? HotKeyModifier.meta : HotKeyModifier.control,
      ],
      scope: HotKeyScope.inapp,
    ),
    keyDownHandler: (_) {
      ref.read(leftPaneProvider.notifier).update((state) {
        return state == leftPaneData.items[0] ? null : leftPaneData.items[0];
      });
    },
  );
  hotKeyManager.register(
    HotKey(
      key: PhysicalKeyboardKey.keyO,
      modifiers: [
        Platform.isMacOS ? HotKeyModifier.meta : HotKeyModifier.control,
      ],
      scope: HotKeyScope.inapp,
    ),
    keyDownHandler: (_) {
      ref.read(leftPaneProvider.notifier).update((state) {
        return state == leftPaneData.items[1] ? null : leftPaneData.items[1];
      });
    },
  );
  hotKeyManager.register(
    HotKey(
      key: PhysicalKeyboardKey.keyF,
      modifiers: [
        Platform.isMacOS ? HotKeyModifier.meta : HotKeyModifier.control,
      ],
      scope: HotKeyScope.inapp,
    ),
    keyDownHandler: (_) {
      ref.read(leftPaneProvider.notifier).update((state) {
        return state == leftPaneData.items[3] ? null : leftPaneData.items[3];
      });
    },
  );
  hotKeyManager.register(
    HotKey(
      key: PhysicalKeyboardKey.keyF,
      modifiers: [
        Platform.isMacOS ? HotKeyModifier.meta : HotKeyModifier.control,
        HotKeyModifier.shift,
      ],
      scope: HotKeyScope.inapp,
    ),
    keyDownHandler: (_) {
      ref.read(leftPaneProvider.notifier).update((state) {
        return state == leftPaneData.items[4] ? null : leftPaneData.items[4];
      });
    },
  );
  hotKeyManager.register(
    HotKey(
      key: PhysicalKeyboardKey.tab,
      modifiers: [HotKeyModifier.control],
      scope: HotKeyScope.inapp,
    ),
    keyDownHandler: (_) {
      final notifier = ref.read(currentTabIndexProvider.notifier);
      final loadedDocuments = ref.read(loadedDocumentsProvider);
      if (loadedDocuments.length > 1) {
        notifier.state = (notifier.state + 1) % loadedDocuments.length;
      }
    },
  );
  hotKeyManager.register(
    HotKey(
      key: PhysicalKeyboardKey.tab,
      modifiers: [HotKeyModifier.control, HotKeyModifier.shift],
      scope: HotKeyScope.inapp,
    ),
    keyDownHandler: (_) {
      final notifier = ref.read(currentTabIndexProvider.notifier);
      final loadedDocuments = ref.read(loadedDocumentsProvider);
      if (loadedDocuments.length > 1) {
        notifier.state =
            (notifier.state - 1 + loadedDocuments.length) %
            loadedDocuments.length;
      }
    },
  );

  topRowNumberKeys.forEach((number, key) {
    hotKeyManager.register(
      HotKey(
        key: key,
        modifiers: [
          Platform.isMacOS ? HotKeyModifier.meta : HotKeyModifier.control,
        ],
        scope: HotKeyScope.inapp,
      ),
      keyDownHandler: (_) {
        final loadedDocuments = ref.read(loadedDocumentsProvider);
        if (number <= loadedDocuments.length) {
          ref.read(currentTabIndexProvider.notifier).state = number - 1;
        }
      },
    );
  });

  hotKeyManager.register(
    HotKey(
      key: PhysicalKeyboardKey.digit0,
      modifiers: [
        Platform.isMacOS ? HotKeyModifier.meta : HotKeyModifier.control,
      ],
      scope: HotKeyScope.inapp,
    ),
    keyDownHandler: (_) {
      final loadedDocuments = ref.read(loadedDocumentsProvider);
      if (loadedDocuments.isNotEmpty) {
        ref.read(currentTabIndexProvider.notifier).state =
            loadedDocuments.length - 1;
      }
    },
  );

  hotKeyManager.register(
    HotKey(
      key: PhysicalKeyboardKey.keyW,
      modifiers: [
        Platform.isMacOS ? HotKeyModifier.meta : HotKeyModifier.control,
      ],
      scope: HotKeyScope.inapp,
    ),
    keyDownHandler: (_) {
      final currentDocument = ref.read(currentDocumentProvider);
      if (currentDocument != null) {
        ref
            .read(loadedDocumentsProvider.notifier)
            .removeDocument(currentDocument.filePath);
      }
    },
  );
});
