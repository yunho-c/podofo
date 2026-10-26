import 'dart:io';

import 'package:podoco/podoco.dart';
import 'package:test/test.dart';

void main() {
  test(
    'pre-extension ABI-2 library rejects crops before resolving the new symbol',
    () async {
      final analyzer = await Analyzer.open(
        await ModelBundle.verify(Platform.environment['PODOCO_M2_BUNDLE']!),
        formulaBundle: await FormulaBundle.verify(
          Platform.environment['PODOCO_M6_BUNDLE']!,
        ),
        options: AnalyzerOptions(
          computePolicy: ComputePolicy.cpuOnly,
          limits: ResourceLimits(
            queuedJobs: 1,
            inputBytes: 16 * 1024 * 1024,
            pendingUpdates: 1,
            resultBytes: 4 * 1024 * 1024,
            maxUpdateBytes: 2 * 1024 * 1024,
            tensorBytes: 128 * 1024 * 1024,
            decoderCacheBytes: 48 * 1024 * 1024,
          ),
        ),
      );
      try {
        expect(analyzer.capabilities.formulaRecognition, true);
        final page = PageDescriptor(
          PageKey(DocumentRef('legacy', '1'), 0),
          PageSpace(10, 10),
        );
        expect(
          () => analyzer.recognizeFormula(
            crop: FormulaCrop(
              page: page,
              regionId: 1,
              bounds: PageRect(0, 0, 10, 10),
              displayKind: FormulaDisplayKind.inline,
            ),
            loadCrop: (_) => throw StateError('Unsupported crop rendered'),
          ),
          throwsA(
            isA<PodocoException>().having(
              (e) => e.code,
              'code',
              'unsupported_capability',
            ),
          ),
        );
      } finally {
        await analyzer.dispose();
      }
      expect(nativeLiveHandles, 0);
    },
    skip: Platform.environment['PODOCO_EXPECT_NO_CROP'] != '1',
  );
}
