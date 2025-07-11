import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

// An Intent represents the purpose of a shortcut.

class QuitIntent extends Intent {
  const QuitIntent();
}

class HideWindowIntent extends Intent {
  const HideWindowIntent();
}

// An Action knows how to perform the work for a given Intent.

class QuitAction extends Action<QuitIntent> {
  @override
  Object? invoke(QuitIntent intent) {
    SystemNavigator.pop();
    return null;
  }
}

class HideWindowAction extends Action<HideWindowIntent> {
  @override
  Object? invoke(HideWindowIntent intent) {
    windowManager.hide();
    return null;
  }
}

// Maps are used to wire up the shortcuts and actions.

final kAppShortcuts = <ShortcutActivator, Intent>{
  // Add quit shortcut for macOS (meta) and Windows/Linux (control).
  const SingleActivator(LogicalKeyboardKey.keyQ, meta: true):
      const QuitIntent(),
  const SingleActivator(LogicalKeyboardKey.keyQ, control: true):
      const QuitIntent(),
  // Add macOS-specific window shortcut.
  if (Platform.isMacOS)
    const SingleActivator(LogicalKeyboardKey.keyH, meta: true):
        const HideWindowIntent(),
};

final kAppActions = <Type, Action<Intent>>{
  QuitIntent: QuitAction(),
  HideWindowIntent: HideWindowAction(),
};
