import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:podofo_one/src/home_page.dart';
import 'package:podofo_one/src/providers.dart';
import 'package:window_manager/window_manager.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await hotKeyManager.unregisterAll();
  await _configureWindowManager();
  runApp(const ProviderScope(child: MyApp()));
}

Future<void> _configureWindowManager() async {
  await windowManager.ensureInitialized();
  const windowOptions = WindowOptions(
    titleBarStyle: TitleBarStyle.hidden,
  );
  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });
}

class MyApp extends ConsumerWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    _registerHotKeys(ref);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Podofo',
      theme: ThemeData.dark(),
      home: const HomePage(),
    );
  }

  void _registerHotKeys(WidgetRef ref) {
    hotKeyManager.register(
      HotKey(
        key: PhysicalKeyboardKey.keyP,
        modifiers: [HotKeyModifier.control],
        scope: HotKeyScope.inapp,
      ),
      keyDownHandler: (_) {
        ref.read(commandPromptProvider.notifier).update((state) => !state);
      },
    );
  }
}
