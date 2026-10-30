import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';

import 'photo_shader_checks.dart';

/// Opt-in local papers: PHOTO_PAPER_CASES is a JSON file containing
/// [{"path":"/path/to/paper.pdf", "pages":[8]}]. No papers are checked in.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final casesPath = Platform.environment['PHOTO_PAPER_CASES'];
  final outputRoot =
      Platform.environment['PHOTO_PAPER_OUTPUT'] ??
      'build/photo-dark-mode/paper-qualification';
  test(
    'real paper photos through the actual Impeller shader',
    () async {
      Pdfrx.pdfiumModulePath = Platform.environment['PDFIUM_PATH'];
      await pdfrxInitialize();
      try {
        final cases = jsonDecode(File(casesPath!).readAsStringSync()) as List;
        for (var i = 0; i < cases.length; i++) {
          final spec = cases[i];
          final output = Directory('$outputRoot/doc-${i + 1}');
          final report = await checkPhotoShader(
            spec['path'],
            output,
            pageNumbers: (spec['pages'] as List).cast<int>(),
            expectedPhotos: null,
          );
          File('${output.path}/report.json').writeAsStringSync(
            const JsonEncoder.withIndent('  ').convert(report),
          );
          // ignore: avoid_print
          print('${output.path}: ${report['analyses']}');
        }
      } finally {
        await PdfrxEntryFunctions.instance.stopBackgroundWorker();
      }
    },
    skip: casesPath == null
        ? 'Set PHOTO_PAPER_CASES for local-paper qualification.'
        : false,
  );
}
