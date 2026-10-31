import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:podoco/podoco.dart' as podoco;
import 'package:podoco_flutter/podoco_flutter.dart';
import 'package:podofo_one/src/analysis/analysis_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('pinned metadata permits cache comparison but never substitutes for payload verification', () async {
    final root = await Directory.systemTemp.createTemp('preview-metadata-');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    try {
      await Directory('${root.path}/layout').create();
      await File('.podoco/model_assets/models/pack.json')
          .copy('${root.path}/pack.json');
      await File('.podoco/model_assets/models/layout/podoco-bundle.yaml')
          .copy('${root.path}/layout/podoco-bundle.yaml');
      messenger.setMockMethodCallHandler(
        NativeModelResources.channel,
        (call) async => call.method == 'platform' ? 'macos-arm64' : root.path,
      );
      final profile = await NativeAnalysisEngine.previewProfile(null);
      expect(profile.layoutModelId, 'pp-doclayout-v3-coreml-mixed-v1');
      expect(profile.layoutAdapter, 'pp-doclayout-v3-v1');
      expect(podoco.nativeLiveHandles, 0);
      await expectLater(
        NativeAnalysisEngine.openBundledLayout((_) {}),
        throwsA(isA<podoco.PodocoException>()),
      );
      // Unpinned custom directories still require the full native verifier even
      // for profile inspection; metadata-only access is restricted to app pins.
      await expectLater(
        NativeAnalysisEngine.previewProfile(
          AnalysisModelPaths('${root.path}/layout'),
        ),
        throwsA(isA<podoco.PodocoException>()),
      );
      expect(podoco.nativeLiveHandles, 0);
    } finally {
      messenger.setMockMethodCallHandler(NativeModelResources.channel, null);
      await root.delete(recursive: true);
    }
  }, skip: Platform.environment['PODOCO_PREVIEW_NATIVE'] != '1');
}
