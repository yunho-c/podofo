import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(pdfrxInitialize);

  for (final rotation in [0, 90, 180, 270]) {
    testWidgets(
      'paints continuous selection and preserves clipboard text at $rotation degrees',
      (tester) async {
        const selectionColor = Color(0xFFFF00FF);
        final document = (await tester.runAsync(
          () => PdfDocument.openData(_pdf(), useProgressiveLoading: false),
        ))!;
        addTearDown(document.dispose);
        // Rotate through the viewer's page API so the same extracted selection is
        // painted in every orientation, independent of PDFium's reading order.
        document.pages = [
          document.pages.first.rotatedTo(
            PdfPageRotation.values[rotation ~/ 90],
          ),
        ];
        final page = document.pages.first;
        final text = (await tester.runAsync(page.loadStructuredText))!;
        expect(text.fullText, contains('The vertical curve'));

        final controller = PdfViewerController();
        final boundaryKey = GlobalKey();
        var ready = false;
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              textSelectionTheme: const TextSelectionThemeData(
                selectionColor: selectionColor,
              ),
            ),
            home: RepaintBoundary(
              key: boundaryKey,
              child: PdfViewer(
                PdfDocumentRefDirect(document, autoDispose: false),
                controller: controller,
                params: PdfViewerParams(
                  onViewerReady: (_, _) => ready = true,
                  sizeDelegateProvider: PdfViewerSizeDelegateProviderLegacy(
                    calculateInitialZoom: (_, _, fitPage, _) => fitPage,
                  ),
                  textSelectionParams: const PdfTextSelectionParams(
                    enableSelectionHandles: false,
                    showContextMenuAutomatically: false,
                  ),
                ),
              ),
            ),
          ),
        );
        await _pumpUntil(tester, () => ready);
        var textReady = false;
        final loadText = controller.textSelectionDelegate.selectAllText().then(
          (_) => textReady = true,
        );
        await _pumpUntil(tester, () => textReady);
        await loadText;

        final start = text.fullText.indexOf('The') + 1;
        final end = text.fullText.indexOf('curve') + 3;
        // Reverse the endpoints on the same page as well as testing partial words.
        await controller.textSelectionDelegate.setTextSelectionPointRange(
          PdfTextSelectionRange.fromPoints(
            PdfTextSelectionPoint(text, end - 1),
            PdfTextSelectionPoint(text, start),
          ),
        );
        await tester.pump();

        final range =
            (await controller.textSelectionDelegate.getSelectedTextRanges())
                .single;
        expect(
          (range.start, range.end, range.text),
          (start, end, 'he vertical cur'),
        );
        final fragments = range.enumerateFragmentBoundingRects().toList();
        final space = fragments.firstWhere((r) => r.fragment.text == ' ');
        final vertical = fragments.firstWhere(
          (r) => r.fragment.text == 'vertical',
        );
        final curve = fragments.firstWhere((r) => r.fragment.text == 'curve');
        // PDFium's generated space is capped, leaving a real visual gap to fill.
        expect(space.bounds.right, lessThan(vertical.bounds.left - 1));
        final wordGap = PdfPoint(
          (space.bounds.right + vertical.bounds.left) / 2,
          vertical.bounds.center.y,
        );
        final columnGap = PdfPoint(
          (vertical.bounds.right + curve.bounds.left) / 2,
          vertical.bounds.center.y,
        );

        final boundary =
            boundaryKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await tester.runAsync(() => boundary.toImage());
        final pixels = (await tester.runAsync(
          () => image!.toByteData(format: ui.ImageByteFormat.rawRgba),
        ))!;
        Color colorAt(PdfPoint point) {
          final documentRect = PdfRect(point.x, point.y, point.x, point.y)
              .toRectInDocument(
                page: page,
                pageRect: controller.layout.pageLayouts.first,
              );
          final offset = boundary.globalToLocal(
            controller.documentToGlobal(documentRect.center)!,
          );
          final index =
              (offset.dy.floor() * image!.width + offset.dx.floor()) * 4;
          return Color.fromARGB(
            pixels.getUint8(index + 3),
            pixels.getUint8(index),
            pixels.getUint8(index + 1),
            pixels.getUint8(index + 2),
          );
        }

        expect(
          colorAt(wordGap),
          selectionColor,
          reason: 'Selected word gaps should be filled',
        );
        expect(
          colorAt(columnGap),
          isNot(selectionColor),
          reason: 'Column gutters should remain open',
        );
        expect(colorAt(text.charRects[start].center), selectionColor);
        expect(
          colorAt(text.charRects[start - 1].center),
          isNot(selectionColor),
        );
        expect(colorAt(text.charRects[end - 1].center), selectionColor);
        expect(colorAt(text.charRects[end].center), isNot(selectionColor));
        image!.dispose();
        expect(
          await controller.textSelectionDelegate.getSelectedText(),
          range.text,
        );

        String? copiedText;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              copiedText = (call.arguments as Map)['text'] as String;
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        expect(
          await controller.textSelectionDelegate.copyTextSelection(),
          isTrue,
        );
        await tester.pump();
        expect(copiedText, 'he vertical cur');
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 100));
      },
    );
  }
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 100 && !ready(); i++) {
    await tester.pump(const Duration(milliseconds: 20));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  expect(ready(), isTrue);
}

// Separate text objects generate spaces with capped rectangles. The first gap
// is ordinary word spacing; the second represents a column gutter.
Uint8List _pdf() {
  const stream =
      'BT /F1 20 Tf 40 140 Td (The) Tj 48 0 Td (vertical) Tj 180 0 Td (curve) Tj ET';
  final objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [4 0 R] /Count 1 >>',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Courier >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 200] '
        '/Resources << /Font << /F1 3 0 R >> >> /Contents 5 0 R >>',
    '<< /Length ${stream.length} >>\nstream\n$stream\nendstream',
  ];
  final pdf = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[0];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(pdf.length);
    pdf.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
  }
  final xref = pdf.length;
  pdf.write('xref\n0 ${offsets.length}\n0000000000 65535 f \n');
  for (final offset in offsets.skip(1)) {
    pdf.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  pdf.write(
    'trailer\n<< /Size ${offsets.length} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF',
  );
  return Uint8List.fromList(ascii.encode(pdf.toString()));
}
