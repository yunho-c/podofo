import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'package:podofo_one/src/data/objectbox.dart';
import 'package:podofo_one/src/providers/providers.dart';
import 'package:podofo_one/src/services/window.dart';
import 'package:podofo_one/src/widgets/screens/default_screen.dart';

late final ObjectBox objectbox;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  objectbox = await ObjectBox.create();
  await hotKeyManager.unregisterAll();
  await configureWindowManager();
  windowManager.addListener(PodofoWindowListener());

  runApp(const ProviderScope(child: MyApp()));
}

class MyApp extends ConsumerWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(hotkeySetupProvider);
    final themeMode =
        ref.watch(themeModeProvider).valueOrNull ?? ThemeMode.system;
    final themeData = ref.watch(themeDataProvider);
    final brightness = ref.watch(brightnessProvider);
    final initialDocuments = ref.watch(initialDocumentsProvider);

    return ShadcnApp(
      debugShowCheckedModeBanner: false,
      title: 'PoDoFo',
      background: brightness == Brightness.light
          ? const Color.fromRGBO(255, 255, 255, 1.0)
          : const Color.fromRGBO(0, 0, 0, 1.0),
      theme: themeData,
      darkTheme: themeData,
      themeMode: themeMode,
      home: initialDocuments.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, stack) => Center(child: Text('Error: $err')),
        data: (_) => const DefaultScreen(),
      ),
    );
  }
}
