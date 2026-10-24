import 'dart:async';
import 'dart:io';

import 'package:pdfrx/pdfrx.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  // Use the same PDFium binary as the built app, including in background workers.
  // Flutter's macOS test runner does not load the app's framework automatically.
  Pdfrx.pdfiumModulePath = Platform.environment['PDFIUM_PATH'];
  await testMain();
}
