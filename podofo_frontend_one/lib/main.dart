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
    final themeMode = ref.watch(themeModeProvider);
    final initialDocuments = ref.watch(initialDocumentsProvider);

    Typography typography = const Typography.geist().copyWith(
      sans: const TextStyle(fontFamily: 'Urbanist'),
    );

    return ShadcnApp(
      debugShowCheckedModeBanner: false,
      title: 'PoDoFo',
      background: themeMode == ThemeMode.light
          ? Color.fromRGBO(255, 255, 255, 1.0)
          : Color.fromRGBO(0, 0, 0, 1.0),
      theme: ThemeData(
        typography: typography,
        colorScheme: ColorSchemes.lightZinc(),
        radius: 0.5,
      ),
      darkTheme: ThemeData(
        typography: typography,
        colorScheme: ColorSchemes.darkZinc(),
        radius: 0.5,
      ),
      themeMode: themeMode,
      home: initialDocuments.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, stack) => Center(child: Text('Error: $err')),
        data: (_) => const DefaultScreen(),
      ),
    );
  }
}
