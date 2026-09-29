import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'package:podofo_one/src/providers/document_provider.dart';
import 'package:podofo_one/src/widgets/panes/outline_pane.dart';

const _outline = [
  PdfOutlineNode(
    title: '  Chapter heading  ',
    dest: null,
    children: [
      PdfOutlineNode(
        title: 'Child section',
        dest: PdfDest(2, PdfDestCommand.fit, null),
        children: [],
      ),
    ],
  ),
  PdfOutlineNode(
    title: 'A very long section title that should stay on a single line',
    dest: PdfDest(3, PdfDestCommand.fit, null),
    children: [],
  ),
];
final _outlineSource = StateProvider<List<PdfOutlineNode>>((ref) => _outline);

class _Controller extends PdfViewerController {
  final destinations = <PdfDest?>[];
  bool ready = true;
  bool failNavigation = false;

  @override
  bool get isReady => ready;

  @override
  Future<bool> goToDest(
    PdfDest? dest, {
    Duration duration = const Duration(milliseconds: 200),
  }) async {
    if (failNavigation) throw StateError('Invalid destination');
    destinations.add(dest);
    return true;
  }
}

Future<ProviderContainer> _mount(
  WidgetTester tester,
  _Controller controller,
) async {
  tester.view.physicalSize = const Size(600, 500);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final container = ProviderContainer(
    overrides: [
      outlineProvider.overrideWith((ref) async => ref.watch(_outlineSource)),
      pdfViewerControllerProvider.overrideWithValue(controller),
    ],
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: ShadcnApp(
        theme: ThemeData(
          typography: const Typography.geist().copyWith(
            sans: () => const TextStyle(fontFamily: 'Urbanist'),
          ),
          colorScheme: ColorSchemes.lightZinc,
        ),
        home: const Center(
          child: RepaintBoundary(
            key: ValueKey('outline-capture'),
            child: ColoredBox(
              color: Color(0xFFFFFFFF),
              child: SizedBox(width: 250, height: 400, child: OutlinePane()),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

Future<void> _capture(WidgetTester tester) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('outline-capture')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/test-artifacts/restored-outline.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

void main() {
  testWidgets(
    'outline groups retain tree keyboard and destination navigation',
    (tester) async {
      final controller = _Controller();
      await _mount(tester, controller);
      expect(find.byType(Tree<PdfOutlineNode>), findsOneWidget);
      expect(find.text('Child section').hitTestable(), findsNothing);
      await tester.tap(find.text('Chapter heading'));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(find.text('Child section').hitTestable(), findsOneWidget);
      expect(controller.destinations, isEmpty);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(controller.destinations.single?.pageNumber, 2);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(find.text('Child section').hitTestable(), findsNothing);
      await tester.tap(find.text(_outline.last.title));
      await tester.pumpAndSettle();
      expect(controller.destinations.last?.pageNumber, 3);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('outline keeps compact styling and resets on document change', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await (FontLoader('Urbanist')..addFont(
            rootBundle.load(
              'assets/fonts/Urbanist/static/Urbanist-Regular.ttf',
            ),
          ))
          .load();
      await (FontLoader('packages/shadcn_flutter/LucideIcons')..addFont(
            rootBundle.load(
              'packages/shadcn_flutter/lib/icons/LucideIcons.ttf',
            ),
          ))
          .load();
    });
    final container = await _mount(tester, _Controller());
    await tester.tap(find.text('Chapter heading'));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    final longTitle = find.text(_outline.last.title);
    final style = DefaultTextStyle.of(tester.element(longTitle));
    expect(style.maxLines, 1);
    expect(style.overflow, TextOverflow.ellipsis);
    await _capture(tester);

    // Rebuild the same outline after an unrelated app update.
    tester.element(find.byType(OutlinePane)).markNeedsBuild();
    await tester.pumpAndSettle();
    expect(find.text('Child section').hitTestable(), findsOneWidget);
    container.read(_outlineSource.notifier).state = [
      PdfOutlineNode(
        title: 'Other chapter',
        dest: null,
        children: _outline.first.children,
      ),
    ];
    await tester.pumpAndSettle();
    expect(find.text('Chapter heading'), findsNothing);
    expect(find.text('Other chapter').hitTestable(), findsOneWidget);
    expect(find.text('Child section').hitTestable(), findsNothing);
    container.read(_outlineSource.notifier).state = [];
    await tester.pumpAndSettle();
    expect(find.text('No outline found'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('outline handles unavailable controllers and navigation errors', (
    tester,
  ) async {
    final controller = _Controller()..ready = false;
    final container = await _mount(tester, controller);
    await tester.tap(find.text(_outline.last.title));
    await tester.pumpAndSettle();
    expect(controller.destinations, isEmpty);
    controller.ready = true;
    controller.failNavigation = true;
    // The click focuses the item; Enter reactivates it without depending on
    // Clickable's double-click detection, which uses wall-clock time.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(
      container.read(documentErrorProvider),
      contains('Invalid destination'),
    );
    expect(tester.takeException(), isNull);
  });
}
