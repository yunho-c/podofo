import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:podofo_one/src/home_page.dart';
import 'package:podofo_one/src/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await hotKeyManager.unregisterAll();
  await _configureWindowManager();

  final windowListener = _MyWindowListener();
  windowManager.addListener(windowListener);

  runApp(const ProviderScope(child: MyApp()));
}

Future<void> _configureWindowManager() async {
  await windowManager.ensureInitialized();

  const windowOptions = WindowOptions(titleBarStyle: TitleBarStyle.hidden);

  windowManager.waitUntilReadyToShow(windowOptions, () async {
    final prefs = await SharedPreferences.getInstance();
    final width = prefs.getDouble('window_width');
    final height = prefs.getDouble('window_height');
    final offsetX = prefs.getDouble('window_offset_x');
    final offsetY = prefs.getDouble('window_offset_y');

    if (width != null && height != null) {
      await windowManager.setSize(Size(width, height));
    }
    if (offsetX != null && offsetY != null) {
      await windowManager.setPosition(Offset(offsetX, offsetY));
    }

    await windowManager.show();
    await windowManager.focus();
  });
}

class MyApp extends ConsumerWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    _registerHotKeys(ref);
    final themeMode = ref.watch(themeProvider);

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Podofo',
      theme: ThemeData.light(),
      darkTheme: ThemeData.dark(),
      themeMode: themeMode,
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

class _MyWindowListener extends WindowListener {
  @override
  Future<void> onWindowClose() async {
    // Save window size and position before closing
    final prefs = await SharedPreferences.getInstance();
    final size = await windowManager.getSize();
    final position = await windowManager.getPosition();
    await prefs.setDouble('window_width', size.width);
    await prefs.setDouble('window_height', size.height);
    await prefs.setDouble('window_offset_x', position.dx);
    await prefs.setDouble('window_offset_y', position.dy);
    super.onWindowClose();
  }
}
