import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:podofo_one/src/dark_mode/photo_analysis.dart';
import 'package:podofo_one/src/dark_mode/photo_geometry.dart';
import 'package:podofo_one/src/dark_mode/photo_mask.dart';
import 'package:podofo_one/src/dark_mode/photo_overrides.dart';
import 'package:podofo_one/src/dark_mode/photo_quality.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PdfDocument document;
  setUpAll(() async {
    await pdfrxInitialize();
    document = await PdfDocument.openFile(
      'test/fixtures/photo_dark_mode/recomposition.pdf',
    );
  });
  tearDownAll(() async {
    await document.dispose();
    await PdfrxEntryFunctions.instance.stopBackgroundWorker();
  });

  test('background proof, annotation exclusion and alpha preserve canonical decisions', () async {
    final specs = jsonDecode(
      File('test/fixtures/photo_dark_mode/recomposition_manifest.json')
          .readAsStringSync(),
    ) as List;
    const quality = PhotoQuality(
      alphaScale: 4,
      coverageDimension: 512,
      captureAlpha: true,
    );
    for (final spec in specs) {
      final number = spec['page'] as int;
      final base = (await analyzePhotos(document, number)).candidates.single;
      final current = (await analyzePhotos(
        document,
        number,
        quality: quality,
      )).candidates.single;
      expect(
        current.recompositionBlocker,
        spec['blocker'],
        reason: spec['name'],
      );
      expect(current.reason, base.reason);
      expect(current.sampleHash, base.sampleHash);
      expect(
        PhotoOverrides.target(document.pages[number - 1], current),
        PhotoOverrides.target(document.pages[number - 1], base),
      );
      if (current.classification != null) {
        final alpha = current.renderCoverage!.alpha!;
        expect(alpha.values, contains(0));
        expect(alpha.values, contains(255));
        expect(alpha.values.any((a) => a > 0 && a < 255), isTrue);
        expect(
          alpha.values.length,
          lessThanOrEqualTo(quality.alphaBytesPerPage),
        );
      } else {
        expect(number, 14);
        expect(current.reason, 'overlapping-page-content');
      }
    }
    for (final dim in [256, 512, 1024]) {
      final q = PhotoQuality(coverageDimension: dim, captureAlpha: true);
      expect(
        q.pageCoverageBytes * q.cachePages,
        lessThanOrEqualTo(PhotoQuality.cacheCoverageBytes),
      );
      expect(q.cachePages, greaterThanOrEqualTo(2));
    }
  });

  test('Impeller removes white contribution at curved red edges at multiple scales and strengths', () async {
    expect(ui.ImageFilter.isShaderFilterSupported, isTrue);
    final page = document.pages[8];
    const quality = PhotoQuality(
      alphaScale: 4,
      coverageDimension: 1024,
      captureAlpha: true,
    );
    final candidate = (await analyzePhotos(
      document,
      9,
      quality: quality,
    )).candidates.single;
    expect(
      candidate.classification,
      isNotNull,
    ); // Flat red is manually overridable.
    expect(candidate.recompositionBlocker, isNull);
    final program = await ui.FragmentProgram.fromAsset(
      'shaders/invert_photos.frag',
    );
    final bounds = ui.Rect.fromLTWH(0, 0, page.width, page.height);
    final mask = await PhotoMask.create(bounds, [
      photoMaskRegion(candidate, page, bounds, recomposeWhite: true),
    ], maxDimension: 4096);
    final inclusive = await PhotoMask.create(bounds, [
      photoMaskRegion(candidate, page, bounds, includeTranslucent: true),
    ], maxDimension: 4096);
    try {
      for (final scale in [1, 2]) {
        final raster = (await page.render(
          fullWidth: page.width * scale,
          fullHeight: page.height * scale,
        ))!;
        final source = await raster.createImage();
        raster.dispose();
        final original = (await source.toByteData())!.buffer.asUint8List();
        try {
          for (final strength in [0.0, .6, 1.0]) {
            final shader = program.fragmentShader();
            mask.configure(shader, strength, bounds);
            final result = await filterImage(source, shader);
            try {
              final pixels = (await result.toByteData())!.buffer.asUint8List();
              var partial = 0, opaque = 0, transparent = 0;
              final errors = <double>[];
              for (var y = 74 * scale; y < 326 * scale; y++) {
                for (var x = 74 * scale; x < 326 * scale; x++) {
                  final offset = (y * source.width + x) * 4;
                  // For a pure red source on white, green is exactly 1-alpha.
                  final background = original[offset + 1].toDouble();
                  if (background > 10 && background < 245) partial++;
                  if (background == 0) opaque++;
                  if (background == 255) transparent++;
                  for (var c = 0; c < 3; c++) {
                    final expected =
                        (original[offset + c] - background * (1 + strength) / 2)
                            .clamp(0, 255);
                    errors.add(
                      (pixels[offset + c] - expected).abs().toDouble(),
                    );
                  }
                }
              }
              errors.sort();
              // Native 1x is exact apart from 8-bit rounding. PDFium samples
              // the page differently at 2x than the independent 4x alpha render:
              // the measured maximum mismatch is 12/255 at this curved edge.
              expect(errors.last, lessThanOrEqualTo(scale == 1 ? 1 : 13));
              expect(
                errors.reduce((a, b) => a + b) / errors.length,
                lessThan(.6),
              );
              expect(partial, greaterThan(100));
              expect(opaque, greaterThan(100));
              expect(transparent, greaterThan(100));
              if (scale == 1 && strength == 1) {
                final directory = Directory('build/photo-dark-mode')
                  ..createSync(recursive: true);
                File('${directory.path}/recomposition-red.png')
                    .writeAsBytesSync(
                      (await result.toByteData(format: ui.ImageByteFormat.png))!
                          .buffer
                          .asUint8List(),
                    );
              }
            } finally {
              result.dispose();
              shader.dispose();
            }
          }
          // The comparison mode should retain a measurable white fringe.
          final shader = program.fragmentShader();
          inclusive.configure(shader, 1, bounds);
          final result = await filterImage(source, shader);
          final pixels = (await result.toByteData())!.buffer.asUint8List();
          var brightEdges = 0;
          for (var i = 0; i < pixels.length; i += 4) {
            if (original[i + 1] > 40 &&
                original[i + 1] < 200 &&
                pixels[i + 1] > 30) {
              brightEdges++;
            }
          }
          expect(brightEdges, greaterThan(100));
          result.dispose();
          shader.dispose();
        } finally {
          source.dispose();
        }
      }
    } finally {
      mask.dispose();
      inclusive.dispose();
    }
  });
  test('photo alpha follows reflections, crops and page rotations against PDFium black-backdrop render', () async {
    final program = await ui.FragmentProgram.fromAsset(
      'shaders/invert_photos.frag',
    );
    for (final number in [1, 10, 11, 12, 13]) {
      final page = document.pages[number - 1];
      final candidate = (await analyzePhotos(
        document,
        number,
        quality: const PhotoQuality(captureAlpha: true),
      )).candidates.single;
      expect(candidate.reason, 'likely-photo');
      expect(candidate.recompositionBlocker, isNull);
      final bounds = ui.Rect.fromLTWH(0, 0, page.width, page.height);
      final mask = await PhotoMask.create(bounds, [
        photoMaskRegion(candidate, page, bounds, recomposeWhite: true),
      ]);
      final white = (await page.render(backgroundColor: 0xffffffff))!;
      final black = (await page.render(backgroundColor: 0xff000000))!;
      final source = await white.createImage();
      final reference = await black.createImage();
      white.dispose();
      black.dispose();
      final shader = program.fragmentShader();
      mask.configure(shader, 1, bounds);
      final actual = await filterImage(source, shader);
      try {
        final a = (await actual.toByteData())!.buffer.asUint8List();
        final b = (await reference.toByteData())!.buffer.asUint8List();
        var maxError = 0, totalError = 0;
        for (var i = 0; i < a.length; i++) {
          final diff = (a[i] - b[i]).abs();
          if (diff > maxError) maxError = diff;
          totalError += diff;
        }
        expect(maxError, lessThanOrEqualTo(4), reason: 'page $number');
        expect(totalError / a.length, lessThan(.1), reason: 'page $number');
        if (number == 1) {
          final dir = Directory('build/photo-dark-mode')
            ..createSync(recursive: true);
          for (final entry in {
            'natural': source,
            'recomposed': actual,
            'reference': reference,
          }.entries) {
            File(
              '${dir.path}/recomposition-photo-${entry.key}.png',
            ).writeAsBytesSync(
              (await entry.value.toByteData(format: ui.ImageByteFormat.png))!
                  .buffer
                  .asUint8List(),
            );
          }
          for (final inclusive in [false, true]) {
            final binary = await PhotoMask.create(bounds, [
              photoMaskRegion(
                candidate,
                page,
                bounds,
                includeTranslucent: inclusive,
              ),
            ]);
            binary.configure(shader, 1, bounds);
            final output = await filterImage(source, shader);
            File(
              '${dir.path}/recomposition-photo-${inclusive ? 'nonzero' : 'opaque'}.png',
            ).writeAsBytesSync(
              (await output.toByteData(format: ui.ImageByteFormat.png))!.buffer
                  .asUint8List(),
            );
            output.dispose();
            binary.dispose();
          }
        }
      } finally {
        actual.dispose();
        reference.dispose();
        source.dispose();
        shader.dispose();
        mask.dispose();
      }
    }
  });
}

Future<ui.Image> filterImage(ui.Image source, ui.FragmentShader shader) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.saveLayer(
    ui.Rect.fromLTWH(0, 0, source.width.toDouble(), source.height.toDouble()),
    ui.Paint()..imageFilter = ui.ImageFilter.shader(shader),
  );
  canvas.drawImage(source, ui.Offset.zero, ui.Paint());
  canvas.restore();
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(source.width, source.height);
  } finally {
    picture.dispose();
  }
}
