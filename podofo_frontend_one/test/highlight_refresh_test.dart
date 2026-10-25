import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:podofo_one/src/services/pdf_highlights.dart';
import 'package:podofo_one/src/services/pdf_session.dart';

import 'fixtures/spaced_text_pdf.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final partial in [false, true]) {
    testWidgets(
      'highlight edits refresh a stationary ${partial ? 'partial' : 'preview'} image',
      (tester) async {
        final temporary = Directory.systemTemp.createTempSync(
          'podofo-refresh-',
        );
        final file = File('${temporary.path}/refresh.pdf')
          ..writeAsBytesSync(spacedTextPdf());
        final session = (await tester.runAsync(() async {
          await pdfrxInitialize(tmpPath: temporary.path);
          return PdfSession.open(file.path);
        }))!;
        final controller = PdfViewerController();
        final boundaryKey = GlobalKey();
        var loaded = false;
        try {
          final text = (await tester.runAsync(
            session.lease.document.pages.single.loadStructuredText,
          ))!;
          final range = PdfPageTextRange(
            pageText: text,
            start: 0,
            end: text.fullText.indexOf('curve'),
          );
          final regions = HighlightRegion.fromTextRanges([
            range,
          ], includeText: true);
          final fragments = range.enumerateFragmentBoundingRects().toList();
          final space = fragments.firstWhere((f) => f.fragment.text == ' ');
          final word = fragments.firstWhere(
            (f) => f.fragment.text == 'vertical',
          );
          final point = PdfPoint(
            (space.bounds.right + word.bounds.left) / 2,
            word.bounds.center.y,
          );
          await tester.pumpWidget(
            MaterialApp(
              home: RepaintBoundary(
                key: boundaryKey,
                child: PdfViewer(
                  session.lease.reference,
                  controller: controller,
                  params: PdfViewerParams(
                    onDocumentLoadFinished: (_, success) => loaded = success,
                    getPageRenderingScale: (_, _, _, _) => partial ? .5 : 4,
                    sizeDelegateProvider: PdfViewerSizeDelegateProviderLegacy(
                      calculateInitialZoom: (_, _, fitPage, _) => fitPage,
                    ),
                  ),
                ),
              ),
            ),
          );
          for (var i = 0; i < 100 && !loaded; i++) {
            await _tick(tester);
          }
          expect(loaded, isTrue);
          // Let both preview and any high-resolution tile settle before editing.
          for (var i = 0; i < 10; i++) {
            await _tick(tester);
          }
          final viewport = controller.value.clone();
          final boundary =
              boundaryKey.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;

          Future<Color> sample() async {
            final rect = PdfRect(point.x, point.y, point.x, point.y)
                .toRectInDocument(
                  page: session.lease.document.pages.single,
                  pageRect: controller.layout.pageLayouts.single,
                );
            final offset = boundary.globalToLocal(
              controller.documentToGlobal(rect.center)!,
            );
            return (await tester.runAsync(() async {
              final image = await boundary.toImage();
              try {
                final data = (await image.toByteData(
                  format: ui.ImageByteFormat.rawRgba,
                ))!;
                final index =
                    (offset.dy.floor() * image.width + offset.dx.floor()) * 4;
                return Color.fromARGB(
                  data.getUint8(index + 3),
                  data.getUint8(index),
                  data.getUint8(index + 1),
                  data.getUint8(index + 2),
                );
              } finally {
                image.dispose();
              }
            }))!;
          }

          Future<void> expectHighlight(
            bool highlighted, {
            bool blue = false,
          }) async {
            bool matches(Color color) => highlighted
                ? (blue
                      ? color.b > .95 && color.r < .8 && color.g < .8
                      : color.r > .95 && color.g > .9 && color.b < .8)
                : color == const Color(0xffffffff);
            Color? last;
            for (var i = 0; i < 60; i++) {
              await _tick(tester);
              last = await sample();
              if (matches(last)) break;
            }
            expect(
              last,
              predicate<Color>(matches),
              reason:
                  'The displayed PDF must ${highlighted ? 'show' : 'remove'} the highlight without scrolling or zooming',
            );
            expect(
              controller.value,
              viewport,
              reason: 'Editing must preserve the viewport',
            );
          }

          await expectHighlight(false);
          await tester.runAsync(() => session.highlight(regions, 0x66ffeb3b));
          await expectHighlight(true);
          await tester.runAsync(session.undoHighlight);
          await expectHighlight(false);
          await tester.runAsync(session.redo);
          await expectHighlight(true);
          final annotations = (await tester.runAsync(session.annotations))!;
          await tester.runAsync(
            () => session.recolorHighlights(
              {annotations.single.id},
              0x660000ff,
              session.revision,
            ),
          );
          await expectHighlight(true, blue: true);
          await tester.runAsync(session.undo);
          await expectHighlight(true);
          await tester.runAsync(session.redo);
          await expectHighlight(true, blue: true);
          await tester.runAsync(session.undo);
          await tester.runAsync(session.undo);
          await expectHighlight(false);
          await tester.runAsync(() => session.highlight(regions, 0x66ffeb3b));
          await expectHighlight(true);
          final highlight = (await tester.runAsync(
            () => PdfHighlights.listPage(session.lease.document, 1),
          ))!.single;
          await tester.runAsync(
            () => session.removeHighlight(highlight, session.revision),
          );
          await expectHighlight(false);
          await tester.runAsync(session.undo);
          await expectHighlight(true);
          await tester.runAsync(session.redo);
          await expectHighlight(false);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(() async {
            await session.close(discard: true);
            await PdfrxEntryFunctions.instance.stopBackgroundWorker();
          });
          temporary.deleteSync(recursive: true);
        }
      },
    );
  }
}

Future<void> _tick(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 10)),
  );
  await tester.pump(const Duration(milliseconds: 20));
}
