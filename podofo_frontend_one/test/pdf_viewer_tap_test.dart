import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(pdfrxInitialize);

  for (final kind in [PointerDeviceKind.mouse, PointerDeviceKind.touch]) {
    for (final onText in [false, true]) {
      testWidgets(
        '$kind tap on ${onText ? 'selection' : 'background'} clears on release',
        (tester) async {
          final changes = <bool>[];
          final view = await _setup(
            tester,
            onSelectionChange: (s) => changes.add(s.hasSelectedText),
          );
          changes.clear();
          final gesture = await tester.createGesture(kind: kind);
          await gesture.down(
            onText ? view.character(1) : view.point(const PdfPoint(300, 50)),
          );
          await tester.pump(const Duration(milliseconds: 20));
          expect(
            view.selection.hasSelectedText,
            isTrue,
            reason: 'Pointer-down may become a drag',
          );
          expect(changes, isEmpty);
          await gesture.up();
          await tester.pump(Duration.zero);
          expect(view.selection.hasSelectedText, isFalse);
          expect(changes, [false]);
          await tester.pump(const Duration(milliseconds: 350));
          expect(changes, [false], reason: 'No delayed duplicate notification');
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  testWidgets(
    'clear cancels pending notification while non-empty changes remain debounced',
    (tester) async {
      final changes = <bool>[];
      final view = await _setup(
        tester,
        onSelectionChange: (s) => changes.add(s.hasSelectedText),
      );
      changes.clear();
      await view.select(1, 4);
      await tester.pump(const Duration(milliseconds: 299));
      expect(changes, isEmpty);
      await tester.pump(const Duration(milliseconds: 1));
      expect(changes, [true]);
      changes.clear();
      await view.select(2, 5);
      await tester.pump(const Duration(milliseconds: 100));
      await view.selection.clearTextSelection();
      expect(changes, isEmpty, reason: 'Notifications remain asynchronous');
      await tester.pump(Duration.zero);
      expect(changes, [false]);
      await tester.pump(const Duration(milliseconds: 350));
      expect(changes, [false]);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('general handler retains delayed consumed taps and double taps', (
    tester,
  ) async {
    final events = <PdfViewerGeneralTapType>[];
    final view = await _setup(
      tester,
      onGeneralTap: (_, _, details) {
        events.add(details.type);
        return true;
      },
    );
    final point = view.point(const PdfPoint(300, 50));
    await _tap(tester, point);
    await tester.pump(const Duration(milliseconds: 299));
    expect(events, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(events, [PdfViewerGeneralTapType.tap]);
    expect(view.selection.hasSelectedText, isTrue);
    events.clear();
    await _doubleTap(tester, point);
    expect(events, [PdfViewerGeneralTapType.doubleTap]);
    expect(view.selection.hasSelectedText, isTrue);
    await tester.pump(const Duration(milliseconds: 350));
    expect(events, [PdfViewerGeneralTapType.doubleTap]);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('tap-only overlay consumes clicks immediately', (tester) async {
    var taps = 0;
    final view = await _setup(
      tester,
      overlay: PdfOverlayInteractionRegion(
        onTap: (_) {
          taps++;
          return true;
        },
        child: const SizedBox.expand(),
      ),
    );
    await _tap(tester, const Offset(100, 100));
    expect(taps, 1);
    expect(view.selection.hasSelectedText, isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('overlay long press and secondary click retain their dispatch', (
    tester,
  ) async {
    final events = <PdfViewerGeneralTapType>[];
    bool handle(PdfOverlayInteractionDetails details) {
      events.add(details.type);
      return true;
    }

    final view = await _setup(
      tester,
      overlay: PdfOverlayInteractionRegion(
        onLongPress: handle,
        onSecondaryTap: handle,
        child: const SizedBox.expand(),
      ),
    );
    final secondary = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await secondary.down(const Offset(100, 100));
    await secondary.up();
    expect(events, [PdfViewerGeneralTapType.secondaryTap]);
    final touch = await tester.createGesture(kind: PointerDeviceKind.touch);
    await touch.down(const Offset(100, 100));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 1));
    await touch.up();
    expect(events, [
      PdfViewerGeneralTapType.secondaryTap,
      PdfViewerGeneralTapType.longPress,
    ]);
    expect(view.selection.hasSelectedText, isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'overlay double taps follow registration changes and only delay their region',
    (tester) async {
      final enabled = ValueNotifier(false);
      addTearDown(enabled.dispose);
      var doubles = 0;
      final view = await _setup(
        tester,
        overlay: ValueListenableBuilder<bool>(
          valueListenable: enabled,
          builder: (_, value, _) => PdfOverlayInteractionRegion(
            onDoubleTap: value
                ? (_) {
                    doubles++;
                    return true;
                  }
                : null,
            child: const SizedBox.expand(),
          ),
        ),
      );
      const inside = Offset(100, 100);
      await _tap(tester, inside);
      expect(view.selection.hasSelectedText, isFalse);
      await view.select(0, 2);
      enabled.value = true;
      await tester.pump(); // Region registers after layout, without rebuilding the viewer.
      await _tap(tester, view.point(const PdfPoint(300, 50)));
      expect(
        view.selection.hasSelectedText,
        isFalse,
        reason: 'Outside the double-tap region',
      );
      await view.select(0, 2);
      await _doubleTap(tester, inside);
      expect(doubles, 1);
      expect(view.selection.hasSelectedText, isTrue);
      enabled.value = false;
      await tester.pump();
      await _tap(tester, inside);
      expect(view.selection.hasSelectedText, isFalse);
      expect(doubles, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('mouse drag still selects text instead of clearing on release', (
    tester,
  ) async {
    final view = await _setup(tester);
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.down(view.character(0));
    await tester.pump(const Duration(milliseconds: 20));
    await gesture.moveTo(view.character(8));
    await tester.pump();
    await gesture.moveTo(view.character(12));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 350));
    expect(view.selection.hasSelectedText, isTrue);
    expect(view.selection.textSelectionPointRange!.end.index, greaterThan(8));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('PDF link consumes a click without clearing selection', (
    tester,
  ) async {
    final links = <PdfLink>[];
    final view = await _setup(tester, onLinkTap: links.add);
    await _tap(tester, view.point(const PdfPoint(100, 40)));
    expect(links, hasLength(1));
    expect(view.selection.hasSelectedText, isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'annotations keep native color and custom metadata without link semantics or cursors',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final document = (await tester.runAsync(
        () => PdfDocument.openData(_pdf(), useProgressiveLoading: false),
      ))!;
      addTearDown(document.dispose);
      final page = document.pages.single;
      final links = (await tester.runAsync(page.loadLinks))!;
      final annotation = links.firstWhere((link) => !link.isNavigable);
      final url = links.firstWhere((link) => link.url != null);
      final controller = PdfViewerController();
      final boundaryKey = GlobalKey();
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      List<PdfLink>? customEntries;
      var ready = false;
      Widget viewer({
        bool enabled = true,
        bool interact = false,
        bool custom = false,
        bool widgets = false,
      }) => MaterialApp(
        home: RepaintBoundary(
          key: boundaryKey,
          child: PdfViewer(
            PdfDocumentRefDirect(document, autoDispose: false),
            controller: controller,
            params: PdfViewerParams(
              onViewerReady: (_, _) => ready = true,
              linkHandlerParams: !enabled || widgets
                  ? null
                  : PdfLinkHandlerParams(
                      onLinkTap: (_) {},
                      enableAnnotationInteraction: interact,
                      linkColor: Colors.blue,
                      customPainter: custom
                          ? (_, _, _, entries) => customEntries = entries
                          : null,
                    ),
              linkWidgetBuilder: widgets
                  ? (_, link, _) => SizedBox(key: ValueKey(link))
                  : null,
            ),
          ),
        ),
      );
      Offset position(PdfLink link) => controller.documentToLocal(
        link.rects.single
            .toRectInDocument(
              page: page,
              pageRect: controller.layout.pageLayouts.single,
            )
            .center,
      );
      Future<int> pixel(PdfLink link) async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(boundaryKey),
        );
        return (await tester.runAsync(() async {
          final image = await boundary.toImage();
          try {
            final bytes = (await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!;
            final point = position(link);
            final offset =
                (point.dy.floor() * image.width + point.dx.floor()) * 4;
            return Color.fromARGB(
              bytes.getUint8(offset + 3),
              bytes.getUint8(offset),
              bytes.getUint8(offset + 1),
              bytes.getUint8(offset + 2),
            ).toARGB32();
          } finally {
            image.dispose();
          }
        }))!;
      }

      Future<void> settle() async {
        for (var i = 0; i < 12; i++) {
          await tester.pump(const Duration(milliseconds: 50));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }
      }

      await tester.pumpWidget(viewer(enabled: false));
      await _pumpUntil(tester, () => ready);
      await settle();
      final annotationColor = await pixel(annotation);
      expect(
        annotationColor,
        isNot(Colors.white.toARGB32()),
        reason: 'Native annotation must be visible',
      );
      for (final interact in [false, true, false]) {
        await tester.pumpWidget(viewer(interact: interact));
        await settle();
        expect(await pixel(annotation), annotationColor);
        expect(await pixel(url), Colors.blue.toARGB32());
        final entries = tester
            .widgetList<Semantics>(find.byType(Semantics))
            .where((w) => w.properties.onTap != null);
        expect(entries.where((w) => w.properties.link == true), hasLength(2));
        expect(
          entries.where((w) => w.properties.button == true),
          hasLength(interact ? 3 : 0),
        );
        await mouse.moveTo(position(annotation));
        await tester.pump();
        expect(
          RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
          interact ? SystemMouseCursors.click : isNot(SystemMouseCursors.click),
        );
        await mouse.moveTo(position(url));
        await tester.pump();
        expect(
          RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
          SystemMouseCursors.click,
        );
      }
      await tester.pumpWidget(viewer(custom: true));
      await settle();
      expect(customEntries, links);
      await tester.pumpWidget(viewer(widgets: true));
      await settle();
      for (final link in links) {
        expect(find.byKey(ValueKey(link)), findsOneWidget);
      }
      semantics.dispose();
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final enableAnnotationInteraction in [false, true]) {
    testWidgets(
      'annotation taps require opt-in ($enableAnnotationInteraction)',
      (tester) async {
        final tapped = <PdfLink>[];
        final view = await _setup(
          tester,
          onLinkTap: tapped.add,
          enableAnnotationInteraction: enableAnnotationInteraction,
        );
        final links = (await tester.runAsync(
          () => view.document.pages.single.loadLinks(),
        ))!;
        expect(links.where((link) => link.isNavigable), hasLength(2));
        expect(links.where((link) => !link.isNavigable), hasLength(3));
        expect(
          links
              .where((link) => !link.isNavigable)
              .every((link) => link.annotation != null),
          isTrue,
        );

        // Author-only and date-only highlights, then a comment annotation.
        for (final annotation in links.where((link) => !link.isNavigable)) {
          tapped.clear();
          await view.select(0, 2);
          await _tap(tester, view.point(annotation.rects.single.center));
          await tester.pump(const Duration(milliseconds: 350));
          expect(tapped, enableAnnotationInteraction ? [annotation] : isEmpty);
          expect(
            view.selection.hasSelectedText,
            enableAnnotationInteraction,
            reason: 'Default annotation taps must fall through to normal selection clearing',
          );
          if (enableAnnotationInteraction) {
            expect(tapped.single.isNavigable, isFalse);
          }
        }

        // Both URL links and in-document destinations remain interactive.
        for (final y in [40.0, 95.0]) {
          tapped.clear();
          await view.select(0, 2);
          await _tap(tester, view.point(PdfPoint(100, y)));
          await tester.pump(const Duration(milliseconds: 350));
          expect(tapped.single.isNavigable, isTrue);
          expect(view.selection.hasSelectedText, isTrue);
        }
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}

Future<void> _tap(WidgetTester tester, Offset position) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.down(position);
  await tester.pump(const Duration(milliseconds: 20));
  await gesture.up();
  await tester.pump();
}

Future<void> _doubleTap(WidgetTester tester, Offset position) async {
  await _tap(tester, position);
  await tester.pump(const Duration(milliseconds: 100));
  await _tap(tester, position);
}

Future<_TestViewer> _setup(
  WidgetTester tester, {
  PdfViewerGeneralTapHandler? onGeneralTap,
  PdfViewerTextSelectionChangeCallback? onSelectionChange,
  Widget? overlay,
  void Function(PdfLink)? onLinkTap,
  bool enableAnnotationInteraction = false,
}) async {
  final document = (await tester.runAsync(
    () => PdfDocument.openData(_pdf(), useProgressiveLoading: false),
  ))!;
  addTearDown(document.dispose);
  final text = (await tester.runAsync(
    document.pages.single.loadStructuredText,
  ))!;
  final controller = PdfViewerController();
  var ready = false;
  await tester.pumpWidget(
    MaterialApp(
      home: PdfViewer(
        PdfDocumentRefDirect(document, autoDispose: false),
        controller: controller,
        params: PdfViewerParams(
          onViewerReady: (_, _) => ready = true,
          onGeneralTap: onGeneralTap,
          linkHandlerParams: onLinkTap == null
              ? null
              : PdfLinkHandlerParams(
                  onLinkTap: onLinkTap,
                  enableAnnotationInteraction: enableAnnotationInteraction,
                ),
          viewerOverlayBuilder: overlay == null
              ? null
              : (_, _, _) => [
                  Positioned(
                    left: 20,
                    top: 20,
                    width: 180,
                    height: 180,
                    child: overlay,
                  ),
                ],
          textSelectionParams: PdfTextSelectionParams(
            enableSelectionHandles: false,
            showContextMenuAutomatically: false,
            onTextSelectionChange: onSelectionChange,
          ),
        ),
      ),
    ),
  );
  await _pumpUntil(tester, () => ready);
  var textReady = false;
  final loading = controller.textSelectionDelegate.selectAllText().then(
    (_) => textReady = true,
  );
  await _pumpUntil(tester, () => textReady);
  await loading;
  final view = _TestViewer(document, controller, text);
  await view.select(0, 2);
  await tester.pump(const Duration(milliseconds: 350));
  return view;
}

class _TestViewer {
  _TestViewer(this.document, this.controller, this.text);
  final PdfDocument document;
  final PdfViewerController controller;
  final PdfPageText text;

  PdfTextSelectionDelegate get selection => controller.textSelectionDelegate;
  Future<void> select(int start, int end) =>
      selection.setTextSelectionPointRange(
        PdfTextSelectionRange.fromPoints(
          PdfTextSelectionPoint(text, start),
          PdfTextSelectionPoint(text, end),
        ),
      );
  Offset character(int index) => point(text.charRects[index].center);
  Offset point(PdfPoint point) => controller.documentToGlobal(
    PdfRect(point.x, point.y, point.x, point.y)
        .toRectInDocument(
          page: document.pages.single,
          pageRect: controller.layout.pageLayouts.single,
        )
        .center,
  )!;
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

Uint8List _pdf() {
  const stream = 'BT /F1 20 Tf 40 140 Td (Selection testing) Tj ET';
  final objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [4 0 R] /Count 1 >>',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Courier >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 200] '
        '/Resources << /Font << /F1 3 0 R >> >> /Contents 5 0 R /Annots [6 0 R 7 0 R 8 0 R 9 0 R 10 0 R] >>',
    '<< /Length ${stream.length} >>\nstream\n$stream\nendstream',
    '<< /Type /Annot /Subtype /Link /Rect [60 20 140 60] '
        '/A << /S /URI /URI (https://example.com/) >> >>',
    '<< /Type /Annot /Subtype /Highlight /Rect [180 20 220 60] /T (Reader) '
        '/C [1 1 0] /QuadPoints [180 60 220 60 180 20 220 20] >>',
    '<< /Type /Annot /Subtype /Highlight /Rect [240 20 280 60] /M (D:20261021000000Z) '
        '/C [1 1 0] /QuadPoints [240 60 280 60 240 20 280 20] >>',
    '<< /Type /Annot /Subtype /Text /Rect [300 20 340 60] /Contents (A comment) >>',
    '<< /Type /Annot /Subtype /Link /Rect [60 80 140 110] /Dest [4 0 R /Fit] >>',
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
