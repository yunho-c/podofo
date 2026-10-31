import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:podofo_one/src/previews/link_target.dart';
import 'package:podofo_one/src/previews/pdf_link_context.dart';
import 'package:podofo_one/src/previews/preview_compositor.dart';
import 'package:podofo_one/src/services/pdf_session.dart';
import 'package:podofo_one/src/workers/link_preview_worker.dart';

import 'support/file_access_mock.dart';

const _root = 'test/fixtures/target_preview';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late PdfSession session;
  late Map<String, dynamic> manifest;
  late List<PdfLink> links;
  final context = PdfLinkContext();
  final worker = LinkPreviewWorker();
  setUpAll(() async {
    installFileAccessMock();
    temp = await Directory.systemTemp.createTemp('preview-compositor-');
    await pdfrxInitialize(tmpPath: temp.path);
    manifest = jsonDecode(
      File('$_root/complex_objects.json').readAsStringSync(),
    );
    final pdf = File('$_root/${manifest['pdf']}');
    expect(
      sha256.convert(await pdf.readAsBytes()).toString(),
      manifest['sha256'],
    );
    expect(
      manifest['layout_source'],
      'hand_annotations_for_grouping_tests_not_detector_output',
    );
    session = await PdfSession.open(pdf.path);
    links = await session.readLocked((pdf) => pdf.pages.first.loadLinks());
  });
  tearDownAll(() async {
    context.clear();
    worker.dispose();
    await session.close();
    await PdfrxEntryFunctions.instance.stopBackgroundWorker();
    await temp.delete(recursive: true);
  });

  test('M4 fixture links and all annotations survive native crop/rotation decoding', () async {
    final pdf = session.lease.document;
    final pages = manifest['pages'] as List;
    final cases = manifest['cases'] as List;
    expect(pdf.pages.length, 6);
    expect(links.length, cases.length);
    for (var i = 0; i < pages.length; i++) {
      final page = pdf.pages[i];
      expect(page.width, pages[i]['size'][0]);
      expect(page.height, pages[i]['size'][1]);
      for (final region in pages[i]['regions'] as List) {
        final bounds = _rect(region['bounds']);
        expect(bounds.isEmpty, false);
        expect(bounds.intersect(ui.Offset.zero & page.size), bounds);
      }
    }
    expect(pdf.pages.last.rotation, PdfPageRotation.clockwise90);
    for (final entry in cases) {
      final source = _rect(entry['source_bounds']);
      final index = links.indexWhere(
        (l) =>
            (l.rects.single.toRect(page: pdf.pages.first).center -
                    source.center)
                .distance <
            .1,
      );
      expect(index, greaterThanOrEqualTo(0), reason: entry['id']);
      final link = links[index];
      expect(link.dest!.pageNumber, entry['destination']['page']);
      final prepared = (await context.prepare(
        LinkPreviewRequest(
          session: session,
          sourcePage: 1,
          annotationIndex: index,
          sourceRects: link.rects,
          destination: link.dest!,
          pixelRatio: 1,
        ),
        () => true,
        null,
      ))!;
      expect(
        prepared.destination!.x,
        closeTo(entry['destination']['point'][0], .01),
      );
      expect(
        prepared.destination!.y,
        closeTo(entry['destination']['point'][1], .01),
      );
      expect(
        prepared.source!.spans.map((s) => s.text).join(),
        entry['source_text'],
      );
      // These annotations test rendering, not automatic target recognition.
      expect(prepared.resolution.tier, LinkTargetTier.unresolved);
      final parts = (entry['required_parts'] as List).map(_part).toList();
      final excluded = (entry['excluded_neighbors'] as List)
          .map(_part)
          .toList();
      for (final part in [...parts, ...excluded]) {
        final page = pdf.pages[part.page - 1];
        expect(part.bounds.isEmpty, false);
        expect(part.bounds.intersect(ui.Offset.zero & page.size), part.bounds);
      }
      expect(
        parts.any(
          (p) => excluded.any(
            (e) => e.page == p.page && e.bounds.overlaps(p.bounds),
          ),
        ),
        false,
      );
    }
  });

  test('complete original pixels survive multipart composition at all density bounds', () async {
    final pdf = session.lease.document;
    final artifacts = await Directory('build/target-preview-m4/compositor')
        .create(recursive: true);
    final report = <Map<String, Object?>>[];
    for (final entry in manifest['cases'] as List) {
      if (entry['kind'] == null) continue;
      final target = ResolvedLinkTarget(
        tier: LinkTargetTier.matchedIdentity,
        kind: LinkTargetKind.values.byName(entry['kind']),
        reason: 'Hand-annotated raster oracle; not resolver output',
        parts: (entry['required_parts'] as List).map(_part).toList(),
      );
      final baseline = (await worker.load(
        session,
        links
            .singleWhere(
              (l) =>
                  (l.rects.single.toRect(page: pdf.pages.first).center -
                          _rect(entry['source_bounds']).center)
                      .distance <
                  .1,
            )
            .dest!,
        pixelRatio: 1,
      ))!;
      try {
        await _save(baseline, '${artifacts.path}/${entry['id']}-context.png');
      } finally {
        baseline.dispose();
      }
      for (final configuration in [
        (ratio: 1.0, size: semanticPreviewMaxSize, name: '1x'),
        (ratio: 2.0, size: semanticPreviewMaxSize, name: '2x'),
        (ratio: 4.0, size: const ui.Size(163, 211), name: 'narrow'),
      ]) {
        final plan = PreviewComposition.plan(
          pdf,
          target,
          configuration.ratio,
          maxSize: configuration.size,
        )!;
        final accounting = PreviewRasterAccounting();
        final image = (await session.readLocked(
          (pdf) => renderResolvedLinkPreview(
            pdf,
            target,
            configuration.ratio,
            LinkPreviewCancellation(),
            maxSize: configuration.size,
            accounting: accounting,
          ),
        ))!;
        try {
          expect(
            image.width,
            lessThanOrEqualTo(
              configuration.size.width * configuration.ratio.clamp(1, 2),
            ),
          );
          expect(
            image.height,
            lessThanOrEqualTo(
              configuration.size.height * configuration.ratio.clamp(1, 2),
            ),
          );
          expect(
            image.width * image.height * 4,
            lessThanOrEqualTo(PreviewComposition.maxBytes),
          );
          expect(accounting.liveBytes, 0);
          expect(accounting.crops, target.parts.length);
          expect(
            accounting.peakBytes,
            lessThanOrEqualTo(2 * PreviewComposition.maxBytes),
          );
          // A separate native crop decoded by pdfrx must match every displayed
          // RGBA pixel. This catches channel swaps, placement, stride, rotation,
          // truncation and ordering errors; padding must remain opaque white.
          final actual = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!.buffer.asUint8List();
          final expected = Uint8List(actual.length)
            ..fillRange(0, actual.length, 255);
          for (final crop in plan.crops) {
            final raster = (await pdf.pages[crop.page - 1].render(
              x: crop.x,
              y: crop.y,
              width: crop.width,
              height: crop.height,
              fullWidth: crop.fullWidth,
              fullHeight: crop.fullHeight,
              backgroundColor: 0xffffffff,
              flags: PdfPageRenderFlags.limitedImageCache,
            ))!;
            try {
              final reference = await raster.createImage();
              try {
                final pixels = (await reference.toByteData(
                  format: ui.ImageByteFormat.rawRgba,
                ))!.buffer.asUint8List();
                for (var y = 0; y < crop.height; y++) {
                  final offset =
                      ((crop.outputY + y) * image.width + crop.outputX) * 4;
                  expected.setRange(
                    offset,
                    offset + crop.width * 4,
                    pixels,
                    y * crop.width * 4,
                  );
                }
              } finally {
                reference.dispose();
              }
            } finally {
              raster.dispose();
            }
          }
          expect(
            actual,
            orderedEquals(expected),
            reason: '${entry['id']} ${configuration.name}',
          );
          await _save(
            image,
            '${artifacts.path}/${entry['id']}-${configuration.name}.png',
          );
          report.add({
            'id': entry['id'],
            'configuration': configuration.name,
            'width': image.width,
            'height': image.height,
            'parts': target.parts.length,
            'peak_accounted_bytes': accounting.peakBytes,
            'live_accounted_bytes': accounting.liveBytes,
            'exact_original_pixels': true,
          });
        } finally {
          image.dispose();
        }
      }
    }
    expect(report, hasLength(27));
    await File('${artifacts.path}/report.json')
        .writeAsString(const JsonEncoder.withIndent('  ').convert(report));
    expect(session.revision, 0);
    expect(session.dirty, false);
    expect(session.navigationHistory.previous, isNull);
  });
}

Future<void> _save(ui.Image image, String path) async {
  final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
  await File(path).writeAsBytes(data.buffer.asUint8List());
}

({int page, ui.Rect bounds}) _part(dynamic data) =>
    (page: data['page'] as int, bounds: _rect(data['bounds']));
ui.Rect _rect(dynamic data) => ui.Rect.fromLTRB(
  (data[0] as num).toDouble(),
  (data[1] as num).toDouble(),
  (data[2] as num).toDouble(),
  (data[3] as num).toDouble(),
);
