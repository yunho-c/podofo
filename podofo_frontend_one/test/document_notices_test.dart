import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:podofo_one/src/providers/document_provider.dart';
import 'package:podofo_one/src/widgets/components/document_notices.dart';

class RecordingPicker extends FilePathNotifier {
  String? recovered;
  @override
  Future<void> pickFile({
    List<String> exts = const ['pdf'],
    String? recoveringPath,
  }) async {
    recovered = recoveringPath;
  }
}

void main() {
  testWidgets(
    'recovery action identifies the failed PDF and fits a narrow window',
    (tester) async {
      tester.view.physicalSize = const Size(360, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const path = '/Users/reader/Documents/a-long-document-name.pdf';
      final picker = RecordingPicker();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            documentFailuresProvider.overrideWith(
              (ref) => {path: 'Operation not permitted'},
            ),
            filePathProvider.overrideWith(() => picker),
          ],
          child: const MaterialApp(home: Scaffold(body: DocumentNotices())),
        ),
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Locate PDF…'));
      await tester.pump();
      expect(picker.recovered, path);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Remove from session'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
