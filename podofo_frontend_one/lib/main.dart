import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:window_manager/window_manager.dart';

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
    final themeMode = ref.watch(themeProvider);
    final initialDocuments = ref.watch(initialDocumentsProvider);

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'PoDoFo',
      theme: ThemeData.light(),
      darkTheme: ThemeData.dark(),
      themeMode: themeMode,
      home: initialDocuments.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, stack) => Center(child: Text('Error: $err')),
        data: (_) => const DefaultScreen(),
      ),
    );
  }
}
