import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart' as material;
import 'package:pdfrx/pdfrx.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'package:podofo_one/src/data/objectbox.dart';
import 'package:podofo_one/src/providers/document_provider.dart';
import 'package:podofo_one/src/providers/theme_provider.dart';
import 'package:podofo_one/src/providers/hotkey_provider.dart';
import 'package:podofo_one/src/providers/data_provider.dart';
import 'package:podofo_one/src/services/window.dart';
import 'package:podofo_one/src/widgets/screens/default_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await pdfrxFlutterInitialize();
  final objectbox = await ObjectBox.create();
  await configureWindowManager();

  runApp(
    ProviderScope(
      overrides: [
        objectboxProvider.overrideWithValue(objectbox),
        desktopWindowProvider.overrideWithValue(true),
      ],
      child: const MyApp(),
    ),
  );
}

class MyApp extends ConsumerWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    final themeData = ref.watch(themeDataProvider);
    final brightness = ref.watch(brightnessProvider);
    final initialDocuments = ref.watch(initialDocumentsProvider);

    return ShadcnApp(
      localizationsDelegates: const [
        material.DefaultMaterialLocalizations.delegate,
      ],
      builder: (context, child) => material.Theme(
        data: material.ThemeData(brightness: brightness),
        child: material.Material(
          type: material.MaterialType.transparency,
          // Preserve Shadcn's typography instead of Material's bodyMedium.
          textStyle: DefaultTextStyle.of(context).style,
          child: child,
        ),
      ),
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
        data: (_) =>
            const DesktopLifecycle(child: AppShortcuts(child: DefaultScreen())),
      ),
    );
  }
}
