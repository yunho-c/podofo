import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';

import 'photo_shader_checks.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'actual Impeller photo preservation and unchanged pixels outside masks',
    () async {
      Pdfrx.pdfiumModulePath = Platform.environment['PDFIUM_PATH'];
      await pdfrxInitialize();
      try {
        final output = Directory('build/photo-dark-mode/impeller-test');
        final report = await checkPhotoShader(
          'test/fixtures/photo_dark_mode/mixed.pdf',
          output,
        );
        report['runner'] =
            'Flutter test with --enable-impeller (not Release app)';
        File(
          '${output.path}/report.json',
        ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
      } finally {
        await PdfrxEntryFunctions.instance.stopBackgroundWorker();
      }
    },
  );
}
