import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:podofo_one/src/services/pdf_session.dart';
import 'package:podofo_one/src/previews/link_target.dart';
import 'package:podofo_one/src/previews/pdf_link_context.dart';
import 'package:podofo_one/src/workers/link_preview_worker.dart';

const _root = 'test/fixtures/target_preview';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporary;
  setUpAll(() async {
    temporary = await Directory.systemTemp.createTemp('target-preview-m0-');
    await pdfrxInitialize(tmpPath: temporary.path);
  });
  tearDownAll(() async {
    await PdfrxEntryFunctions.instance.stopBackgroundWorker();
    await temporary.delete(recursive: true);
  });

  test(
    'M0 fixture preserves real links, target geometry, and baseline crops',
    () async {
      final manifest = _manifest('linked_objects.json');
      await _verifyDocument(Directory(_root), manifest, temporary);
    },
  );

  final corpus = Platform.environment['TARGET_PREVIEW_CORPUS_DIR'];
  test(
    'frozen real-paper links resolve and produce contextual baseline crops',
    () async {
      for (final document
          in _manifest('real_papers.json')['documents'] as List) {
        await _verifyDocument(Directory(corpus!), document as Map, temporary);
      }
    },
    skip: corpus == null
        ? 'Set TARGET_PREVIEW_CORPUS_DIR to the frozen PDFs'
        : false,
  );
}

Map<String, dynamic> _manifest(String name) =>
    jsonDecode(File('$_root/$name').readAsStringSync()) as Map<String, dynamic>;

Future<void> _verifyDocument(
  Directory source,
  Map manifest,
  Directory temporary,
) async {
  final bytes = await File('${source.path}/${manifest['pdf']}').readAsBytes();
  expect(sha256.convert(bytes).toString(), manifest['sha256']);
  final file = await File('${temporary.path}/${manifest['pdf']}')
      .writeAsBytes(bytes);
  final session = await PdfSession.open(file.path);
  final worker = LinkPreviewWorker();
  final context = PdfLinkContext();
  final artifacts = await Directory('build/target-preview-m0/native')
      .create(recursive: true);
  try {
    final pdf = session.lease.document;
    final sizes = manifest['page_sizes'] as List;
    expect(pdf.pages.length, sizes.length);
    for (var i = 0; i < sizes.length; i++) {
      expect(pdf.pages[i].width, closeTo((sizes[i][0] as num).toDouble(), .01));
      expect(
        pdf.pages[i].height,
        closeTo((sizes[i][1] as num).toDouble(), .01),
      );
    }
    for (final entry in manifest['cases'] as List) {
      final id = entry['id'] as String;
      final sourcePage = pdf.pages[(entry['source_page'] as int) - 1];
      final links = await session.readLocked((_) => sourcePage.loadLinks());
      final expectedSource = _rect(entry['source_bounds']);
      // Native and independent parsers need not enumerate annotations identically.
      final link = links.singleWhere(
        (link) => link.rects.any(
          (rect) =>
              (rect.toRect(page: sourcePage).center - expectedSource.center)
                  .distance <
              .1,
        ),
      );
      final sourceRect = link.rects.single.toRect(page: sourcePage);
      expect(sourceRect.left, closeTo(expectedSource.left, .01), reason: id);
      expect(sourceRect.top, closeTo(expectedSource.top, .01), reason: id);
      expect(sourceRect.right, closeTo(expectedSource.right, .01), reason: id);
      expect(
        sourceRect.bottom,
        closeTo(expectedSource.bottom, .01),
        reason: id,
      );
      expect(
        _normalize((await sourcePage.loadText())!.fullText),
        contains(_normalize(entry['source_text'] as String)),
        reason: id,
      );
      final destination = entry['destination'] as Map;
      final dest = link.dest!;
      expect(link.url, isNull, reason: id);
      expect(dest.command, PdfDestCommand.xyz, reason: id);
      expect(dest.pageNumber, destination['page'], reason: id);
      final page = pdf.pages[dest.pageNumber - 1];
      final point = destination['point'] as List;
      // These corpus pages are unrotated with zero-origin MediaBox/CropBox.
      // Separate native geometry tests cover offsets and all rotations.
      expect(
        dest.params![0],
        closeTo((point[0] as num).toDouble(), .01),
        reason: id,
      );
      expect(
        dest.params![1],
        closeTo(page.height - (point[1] as num), .01),
        reason: id,
      );
      final targetText = _normalize((await page.loadText())!.fullText);
      for (final expected in entry['expected_target_text'] as List) {
        expect(
          targetText,
          contains(_normalize(expected as String)),
          reason: id,
        );
      }
      final required = (entry['required_parts'] as List).map(_rect).toList();
      final excluded = (entry['excluded_neighbors'] as List)
          .map(_rect)
          .toList();
      for (final rect in [...required, ...excluded]) {
        expect(rect.isEmpty, false, reason: id);
        expect(
          rect.left >= 0 &&
              rect.top >= 0 &&
              rect.right <= page.width &&
              rect.bottom <= page.height,
          true,
          reason: id,
        );
      }
      expect(required.any((r) => excluded.any(r.overlaps)), false, reason: id);
      final prepared = (await context.prepare(
        LinkPreviewRequest(
          session: session,
          sourcePage: sourcePage.pageNumber,
          annotationIndex: links.indexOf(link),
          sourceRects: link.rects,
          destination: dest,
          pixelRatio: 1,
        ),
        () => true,
        null,
      ))!;
      expect(prepared.resolution.tier, LinkTargetTier.unresolved, reason: id);
      expect(
        prepared.destination!.x,
        closeTo((point[0] as num).toDouble(), .01),
      );
      expect(
        prepared.destination!.y,
        closeTo((point[1] as num).toDouble(), .01),
      );
      expect(
        _normalize(prepared.source!.spans.map((s) => s.text).join()),
        contains(_normalize(entry['source_text'] as String)),
        reason: id,
      );
      final image = (await worker.load(session, dest, pixelRatio: 1))!;
      try {
        expect(image.width, lessThanOrEqualTo(360), reason: id);
        expect(image.height, lessThanOrEqualTo(240), reason: id);
        final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        await File('${artifacts.path}/$id-context.png')
            .writeAsBytes(png.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    }
    expect(session.dirty, false);
    expect(session.revision, 0);
    expect(session.navigationHistory.previous, isNull);
  } finally {
    context.clear();
    worker.dispose();
    await session.close();
  }
}

// PDFium marks discretionary hyphens with U+0002; the independent parser uses '-'.
String _normalize(String text) =>
    text.replaceAll('\u0002', '-').replaceAll(RegExp(r'\s+'), ' ').trim();

ui.Rect _rect(dynamic value) {
  final bounds = (value as List).cast<num>();
  return ui.Rect.fromLTRB(
    bounds[0].toDouble(),
    bounds[1].toDouble(),
    bounds[2].toDouble(),
    bounds[3].toDouble(),
  );
}
