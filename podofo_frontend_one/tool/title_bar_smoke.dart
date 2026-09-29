// An isolated native-window fixture. It never opens the user's database or PDFs.
// flutter build windows --release -t tool/title_bar_smoke.dart
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:podofo_one/main.dart';
import 'package:podofo_one/src/providers/document_provider.dart';
import 'package:podofo_one/src/providers/user_state_provider.dart';
import 'package:podofo_one/src/services/window.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

class _SmokeUserState extends UserStateNotifier {
  @override
  UserState build() => UserState()
    ..highlightColor = '#66ffeb3b'
    ..highlightColorPalette = ['#66ffeb3b'];
}

class _CloseWitness with WindowListener {
  _CloseWitness(this.path);
  final String path;

  @override
  void onWindowClose() => File(path).writeAsStringSync('close reached Dart');
}

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  await configureWindowManager();
  if (arguments.isNotEmpty) {
    windowManager.addListener(_CloseWitness(arguments.single));
  }
  final container = ProviderContainer(
    overrides: [
      initialDocumentsProvider.overrideWith((ref) async => {}),
      userStateNotifierProvider.overrideWith(_SmokeUserState.new),
      desktopWindowProvider.overrideWithValue(true),
    ],
  );
  await container.read(initialDocumentsProvider.future);
  runApp(UncontrolledProviderScope(container: container, child: const MyApp()));
  WidgetsBinding.instance.addPostFrameCallback((_) {
    windowManager.setTitle('PoDoFo caption test');
  });
}
