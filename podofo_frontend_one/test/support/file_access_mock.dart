import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:podofo_one/src/services/document_file_access.dart';

Future<Object?> ordinaryFileAccess(MethodCall call) async {
  final args = call.arguments as Map;
  switch (call.method) {
    case 'acquire':
      return {'path': args['path']};
    case 'read':
      final path = await File(args['path'] as String).resolveSymbolicLinks();
      return {'path': path, 'bytes': await File(path).readAsBytes()};
    case 'remember':
    case 'release':
      return null;
    case 'stagingDirectory':
      return (await Directory(p.dirname(args['path'] as String))
              .createTemp('.podofo-test-save-'))
          .path;
    default:
      throw MissingPluginException(call.method);
  }
}

void installFileAccessMock([Future<Object?> Function(MethodCall)? handler]) {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        DocumentFileAccess.channel,
        handler ?? ordinaryFileAccess,
      );
}
