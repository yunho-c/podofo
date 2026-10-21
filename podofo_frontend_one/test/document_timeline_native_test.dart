import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mlsr_app_models/app_models.dart';
import 'package:mlsr_flutter/mlsr_flutter.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:podofo_one/objectbox.g.dart';
import 'package:podofo_one/src/narration/mlsr_narrator.dart';
import 'package:podofo_one/src/narration/narration_controller.dart';
import 'package:podofo_one/src/services/narration_bookmarks.dart';
import 'package:podofo_one/src/services/pdf_session.dart';

import '../tool/document_timeline_probe.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'real PDF and native complete document timeline',
    () async {
      const channel = MethodChannel('dev.mlsr.flutter/models');
      final resources = Directory(
        '.mlsr/model_assets/${AppModels.supertonic3.assetPath}',
      ).absolute;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (call) async => switch (call.method) {
              'platform' => 'macos-arm64',
              'locate' => resources.path,
              _ => throw StateError('Unexpected resource call: ${call.method}'),
            },
          );
      final output = Directory(
        'build/document-timeline-qualification/milestone6/native',
      );
      await output.create(recursive: true);
      await pdfrxInitialize(tmpPath: output.absolute.path);
      final database = await Directory.systemTemp.createTemp(
        'timeline-database-',
      );
      final store = await openStore(directory: database.path);
      final bookmarks = NarrationBookmarks(store);
      final tts = await FlutterMlsr.openTts(model: AppModels.supertonic3);
      final controller = NarrationController(
        open: (_) async => MlsrNarrator.fromTts(tts, volume: 0),
        onPosition: (source, anchor) {
          if (source.documentId case final PdfSession document) {
            bookmarks.save(document.path, anchor);
          }
        },
      );
      try {
        final result = await qualifyDocumentTimeline(
          controller,
          tts,
          bookmarks,
          output,
        );
        expect(result['passed'], true);
      } finally {
        await controller.close();
        store.close();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        await PdfrxEntryFunctions.instance.stopBackgroundWorker();
        await database.delete(recursive: true);
      }
    },
    skip: Platform.environment['PODOFO_TEST_MLSR'] != '1',
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
