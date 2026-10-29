import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:pdfrx/pdfrx.dart';

import 'photo_shader_checks.dart';

/// flutter run -d macos --release -t tool/photo_release_probe.dart
///   --dart-define=PHOTO_FIXTURE=/absolute/path/mixed.pdf
///   --dart-define=PHOTO_OUTPUT=/absolute/path/new-evidence-directory
/// On sandboxed macOS, put both paths within the app's accessible container.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kReleaseMode) throw StateError('Build this probe in Release mode');
  const fixture = String.fromEnvironment('PHOTO_FIXTURE');
  const destination = String.fromEnvironment('PHOTO_OUTPUT');
  if (fixture.isEmpty || destination.isEmpty) {
    throw StateError('Set PHOTO_FIXTURE and PHOTO_OUTPUT');
  }
  final output = Directory(destination);
  if (output.existsSync()) throw StateError('Use a new evidence directory');
  runApp(
    const Directionality(
      textDirection: TextDirection.ltr,
      child: Center(child: Text('Running photo shader qualification…')),
    ),
  );
  await pdfrxFlutterInitialize();
  try {
    final report = await checkPhotoShader(fixture, output);
    report['runner'] = 'Release app offscreen Impeller';
    report['platform'] = Platform.operatingSystem;
    File('${output.path}/report.json')
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
    runApp(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(child: Text('Photo shader pixel checks passed.')),
      ),
    );
  } catch (error, stack) {
    output.createSync(recursive: true);
    File('${output.path}/failure.txt').writeAsStringSync('$error\n$stack');
    rethrow;
  }
}
