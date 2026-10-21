import 'dart:async';
import 'dart:io';

import 'package:pdfrx/pdfrx.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/file_access_mock.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  // Use the same PDFium binary as the built app, including in background workers.
  // Flutter's macOS test runner does not load the app's framework automatically.
  Pdfrx.pdfiumModulePath = Platform.environment['PDFIUM_PATH'];
  // Unit/widget runners do not load Runner's macOS method channel. Production
  // deliberately has no MissingPlugin fallback, so a broken bridge fails loudly.
  setUp(installFileAccessMock);
  await testMain();
}
