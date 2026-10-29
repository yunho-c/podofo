// Opt-in capture job, driven by run.py. Not a native macOS compositor test.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart' as material;
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pdfrx/pdfrx.dart';
import 'package:podofo_one/src/data/document_data.dart';
import 'package:podofo_one/src/narration/narration_controller.dart';
import 'package:podofo_one/src/providers/document_provider.dart';
import 'package:podofo_one/src/providers/narration_provider.dart';
import 'package:podofo_one/src/providers/theme_provider.dart';
import 'package:podofo_one/src/providers/user_state_provider.dart';
import 'package:podofo_one/src/services/pdf_session.dart';
import 'package:podofo_one/src/widgets/components/custom_pdf_viewer.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import '../../test/support/file_access_mock.dart';
import 'measure.dart';
import 'native_reference.dart';

class _Preferences extends UserStateNotifier {
  @override
  UserState build() => UserState()..autoSaveEnabled = false;
}

// WidgetTester.runAsync otherwise forwards native errors to the test binding
// and returns null, hiding the useful error from our per-case failure receipt.
Future<T> _real<T>(WidgetTester tester, Future<T> Function() operation) async {
  Object? failure;
  StackTrace? trace;
  final value = await tester.runAsync(() async {
    try {
      return await operation();
    } catch (error, stack) {
      failure = error;
      trace = stack;
      return null;
    }
  });
  if (failure != null) Error.throwWithStackTrace(failure!, trace!);
  return value as T;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final configPath = Platform.environment['RENDER_QUALITY_CONFIG'];
  testWidgets(
    'capture production PDF viewer and direct PDFium reference',
    (tester) async {
      final config = jsonDecode(
        File(configPath!).readAsStringSync(),
      ) as Map<String, dynamic>;
      final out = Directory(config['output'] as String);
      final module = config['pdfium'] as String;
      final result = <String, Object?>{
        'schema_version': 1,
        'passed': false,
        'boundary': 'Flutter widget-test raster capture; not native GPU/compositor qualification',
        'calibration': calibration(),
        'cases': <Map<String, Object?>>[],
      };
      void save() {
        final temporary = File('${out.path}/results.json.tmp');
        temporary.writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(result),
        );
        temporary.renameSync('${out.path}/results.json');
      }

      save();
      Pdfrx.pdfiumModulePath = module;
      installFileAccessMock();
      await _real(tester, () => pdfrxInitialize(tmpPath: out.path));
      try {
        final fixture = '${out.path}/fixture.pdf';
        await _real(
          tester,
          () => createFixture(
            fixture,
            module,
            'assets/fonts/Urbanist/static/Urbanist-Regular.ttf',
          ),
        );
        result['geometry_calibration'] = await _real(
          tester,
          () => _verifyGeometry(fixture, module),
        );
        save();
        for (final entry
            in (config['cases'] as List).cast<Map<String, dynamic>>()) {
          final row = <String, Object?>{...entry, 'status': 'running'};
          (result['cases'] as List).add(row);
          save();
          try {
            await _capture(tester, entry, out, module, fixture, row);
            row['status'] = 'complete';
          } on UnsupportedError catch (error) {
            row['status'] = 'unsupported';
            row['error'] = error.toString();
          } catch (error, stack) {
            row['status'] = 'failed';
            row['error'] = error.toString();
            row['stack'] = stack.toString();
          }
          save();
        }
        result['passed'] = (result['cases'] as List).every(
          (r) => r['status'] == 'complete',
        );
        expect(
          result['passed'],
          isTrue,
          reason: 'See results.json for failed/unsupported cases',
        );
      } catch (error, stack) {
        result['error'] = error.toString();
        result['stack'] = stack.toString();
        rethrow;
      } finally {
        save();
        await tester.pumpWidget(const SizedBox.shrink());
        await _real(
          tester,
          () => PdfrxEntryFunctions.instance.stopBackgroundWorker(),
        );
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      }
    },
    skip: configPath == null,
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

Future<Map<String, Object?>> _verifyGeometry(
  String fixture,
  String module,
) async {
  final document = await PdfDocument.openFile(
    fixture,
    useProgressiveLoading: false,
  );
  final scores = <Object?>[];
  try {
    for (final page in document.pages) {
      final width = (page.width * 2).round(),
          height = (page.height * 2).round();
      final reference = await referencePixels(document, (
        module: module,
        page: page.pageNumber,
        width: width,
        height: height,
        scale: 2,
        left: 0,
        top: 0,
      ));
      final raw = await page.render(
        fullWidth: width.toDouble(),
        fullHeight: height.toDouble(),
        flags: PdfPageRenderFlags.limitedImageCache,
      );
      if (raw == null) {
        throw StateError('Integer geometry control failed to render');
      }
      late Uint8List ordinary;
      try {
        ordinary = rgbaImageFromBgra(raw.pixels, raw.width, raw.height);
      } finally {
        raw.dispose();
      }
      final score = measure(reference, ordinary, width, height, (
        left: 0,
        top: 0,
        right: width,
        bottom: height,
      ));
      // Matrix rendering must agree with the independent integer-size API.
      if ((score['mae_8bit'] as double) > .01 ||
          (score['different_fraction_gt_2'] as double) > .0001) {
        throw StateError(
          'Reference crop/rotation calibration failed on page ${page.pageNumber}: $score',
        );
      }
      if (page.pageNumber == 1) {
        final red = (96 * width + 92) * 4;
        if (reference[red] < 250 ||
            reference[red + 1] > 5 ||
            reference[red + 2] > 5) {
          throw StateError('Known alignment mark is misplaced');
        }
      }
      scores.add({
        'page': page.pageNumber,
        'rotation': page.rotation.index * 90,
        ...score,
      });
    }
  } finally {
    await document.dispose();
  }
  return {'passed': true, 'integer_api_comparisons': scores};
}

Uint8List rgbaImageFromBgra(Uint8List bytes, int width, int height) =>
    img.Image.fromBytes(
      width: width,
      height: height,
      bytes: bytes.buffer,
      bytesOffset: bytes.offsetInBytes,
      order: img.ChannelOrder.bgra,
    ).getBytes(order: img.ChannelOrder.rgba);

Future<void> _capture(
  WidgetTester tester,
  Map<String, dynamic> entry,
  Directory out,
  String module,
  String fixture,
  Map<String, Object?> row,
) async {
  final pdf = entry['pdf'] as String? ?? fixture;
  final pageNumber = entry['page'] as int;
  final dpi = (entry['dpi'] as num).toDouble(),
      dpr = (entry['dpr'] as num).toDouble();
  final phase = (entry['offset'] as num).toDouble();
  final width = (800 * dpr).round(), height = (600 * dpr).round();
  final dir = Directory('${out.path}/${entry['id']}')..createSync();
  row['pdf'] = pdf;
  row['pdf_sha256'] = sha256.convert(File(pdf).readAsBytesSync()).toString();
  row['capture_size'] = [width, height];
  final session = await _real(tester, () => PdfSession.open(pdf));
  final controller = PdfViewerController();
  final narrator = NarrationController(
    open: (_) async => throw StateError('Narration must stay inactive'),
  );
  final container = ProviderContainer(
    overrides: [
      currentDocumentProvider.overrideWithValue(
        Document(session: session, lastOpenedPage: pageNumber),
      ),
      pdfViewerControllerProvider.overrideWithValue(controller),
      pdfTextSearcherProvider.overrideWithValue(null),
      userStateNotifierProvider.overrideWith(_Preferences.new),
      brightnessProvider.overrideWithValue(Brightness.light),
      shaderProvider.overrideWithValue(null),
      narrationControllerProvider.overrideWithValue(narrator),
    ],
  );
  final boundaryKey = GlobalKey();
  try {
    if (pageNumber < 1 || pageNumber > session.lease.document.pages.length) {
      throw ArgumentError('Page $pageNumber is outside this document');
    }
    tester.view.devicePixelRatio = dpr;
    tester.view.physicalSize = Size(width.toDouble(), height.toDouble());
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: ShadcnApp(
          localizationsDelegates: const [
            material.DefaultMaterialLocalizations.delegate,
          ],
          home: RepaintBoundary(
            key: boundaryKey,
            child: const CustomPdfViewer(),
          ),
        ),
      ),
    );
    await _wait(
      tester,
      () =>
          controller.isReady &&
          container.read(viewerReadyProvider) == controller,
    );
    final page = controller.pages[pageNumber - 1];
    final layout = controller.layout.pageLayouts[pageNumber - 1];
    final zoom = dpi / 72 / dpr;
    final matrix = controller.calcMatrixFor(layout.center, zoom: zoom);
    // Offset relative to the unmodified centered viewport. This tests subpixel
    // placement without realigning either captured image after rendering.
    matrix.storage[12] += phase / dpr;
    matrix.storage[13] += phase / dpr;
    final stopwatch = Stopwatch()..start();
    controller.value = matrix;
    await tester.pump();
    await tester.pump();
    for (var i = 0; i < 16; i++) {
      if ((controller.value.storage[i] - matrix.storage[i]).abs() > 1e-7) {
        throw UnsupportedError(
          'Requested viewport was clamped; choose a larger zoom or offset 0.',
        );
      }
    }
    bool ready() {
      final status = controller.renderingStatus.value
          .where((p) => p.pageNumber == pageNumber)
          .firstOrNull;
      if (status == null || (status.targetScale - dpi / 72).abs() > 1e-7) {
        return false;
      }
      return status.mode ==
          (status.targetScale > status.previewScale
              ? PdfPageRenderMode.fullResolution
              : PdfPageRenderMode.preview);
    }

    await _wait(tester, ready);
    final status = controller.renderingStatus.value.firstWhere(
      (p) => p.pageNumber == pageNumber,
    );
    row['settle_wall_ms'] = stopwatch.elapsedMicroseconds / 1000;
    row['mode'] = status.mode.name;
    row['target_scale'] = status.targetScale;
    row['preview_scale'] = status.previewScale;
    row['transform'] = controller.value.storage.toList();
    row['page_size'] = [page.width, page.height];
    row['rotation'] = page.rotation.index * 90;
    final boundary =
        boundaryKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
    final origin = boundary.globalToLocal(
      controller.documentToGlobal(layout.topLeft)!,
    );
    final left = origin.dx * dpr, top = origin.dy * dpr;
    row['page_origin_physical'] = [left, top];
    row['fractional_origin'] = [left - left.floor(), top - top.floor()];
    final reference = await _real(
      tester,
      () => session.lease.use(
        (doc) => referencePixels(doc, (
          module: module,
          page: pageNumber,
          width: width,
          height: height,
          scale: dpi / 72,
          left: left,
          top: top,
        )),
      ),
    );
    Future<Uint8List> capture() => _real(tester, () async {
      final image = await boundary.toImage(pixelRatio: dpr);
      try {
        if (image.width != width || image.height != height) {
          throw StateError('Unexpected capture dimensions');
        }
        return (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!
            .buffer
            .asUint8List();
      } finally {
        image.dispose();
      }
    });
    final candidate = await capture();
    // A second painted frame verifies stability, not just replaying the same buffer.
    controller.invalidate();
    await tester.pump();
    await _wait(tester, ready);
    final repeated = await capture();
    final referenceImage = rgbaImage(reference, width, height);
    final candidateImage = rgbaImage(candidate, width, height);
    File('${dir.path}/reference.png')
        .writeAsBytesSync(img.encodePng(referenceImage));
    File('${dir.path}/podofo.png')
        .writeAsBytesSync(img.encodePng(candidateImage));
    File('${dir.path}/difference.png').writeAsBytesSync(
      img.encodePng(differenceImage(reference, candidate, width, height)),
    );
    // Explicit mask: page interior (2px inset), minus the rightmost 24 logical
    // pixels reserved for the production scrollbar. Preserve full PNGs too.
    final rect = (
      left: math.max(0, (left + 2).ceil()),
      top: math.max(0, (top + 2).ceil()),
      right: math.min(
        width - (24 * dpr).ceil(),
        (left + page.width * dpi / 72 - 2).floor(),
      ),
      bottom: math.min(height, (top + page.height * dpi / 72 - 2).floor()),
    );
    final metrics = <String, Object?>{
      'content': measure(reference, candidate, width, height, rect),
    };
    if (entry['pdf'] == null && pageNumber == 1) {
      for (final region in fixtureRegions.entries) {
        final r = region.value, s = dpi / 72;
        final regionRect = (
          left: math.max(rect.left, (left + r[0] * s).ceil()),
          top: math.max(rect.top, (top + r[1] * s).ceil()),
          right: math.min(rect.right, (left + (r[0] + r[2]) * s).floor()),
          bottom: math.min(rect.bottom, (top + (r[1] + r[3]) * s).floor()),
        );
        if (regionRect.right > regionRect.left &&
            regionRect.bottom > regionRect.top) {
          metrics[region.key] = measure(
            reference,
            candidate,
            width,
            height,
            regionRect,
          );
        }
      }
    }
    row['metrics'] = metrics;
    final repeat = measure(candidate, repeated, width, height, rect);
    row['repeat'] = repeat;
    row['capture_pair_bytes'] = width * height * 4 * 2;
    row['preview_bitmap_bytes_estimate'] =
        (page.width * status.previewScale).floor() *
        (page.height * status.previewScale).floor() *
        4;
    row['viewport_bitmap_bytes_estimate'] =
        status.mode == PdfPageRenderMode.fullResolution
        ? (layout.intersect(controller.visibleRect).width * dpi / 72).floor() *
              (layout.intersect(controller.visibleRect).height * dpi / 72)
                  .floor() *
              4
        : 0;
    if (repeat['mae_8bit'] != 0) {
      throw StateError('Repeated capture is not pixel-stable');
    }
    expect(tester.takeException(), isNull);
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    narrator.dispose();
    await _real(tester, () => session.close(discard: true));
  }
}

Future<void> _wait(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 300; i++) {
    await _real(
      tester,
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump();
    if (ready()) return;
  }
  throw StateError('Timed out waiting for the requested viewer render');
}
