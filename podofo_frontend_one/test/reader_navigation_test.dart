import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:podofo_one/main.dart';
import 'package:podofo_one/objectbox.g.dart';
import 'package:podofo_one/src/data/document_entity.dart';
import 'package:podofo_one/src/data/objectbox.dart';
import 'package:podofo_one/src/narration/narration_controller.dart';
import 'package:podofo_one/src/narration/narrator.dart';
import 'package:podofo_one/src/narration/paper_plan.dart';
import 'package:podofo_one/src/narration/paper_sequence.dart';
import 'package:podofo_one/src/providers/data_provider.dart';
import 'package:podofo_one/src/providers/document_provider.dart';
import 'package:podofo_one/src/providers/narration_provider.dart';
import 'package:podofo_one/src/providers/tab_provider.dart';
import 'package:podofo_one/src/services/pdf_session.dart';
import 'package:podofo_one/src/widgets/components/pdf_back_button.dart';
import 'package:podofo_one/src/widgets/components/pdf_selection_menu.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures/linked_pdf_fixture.dart';
import 'reader_widget_test.dart' show captureReader, waitForNative;
import 'support/fake_narrator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final platform = Platform.isMacOS
      ? TargetPlatform.macOS
      : TargetPlatform.windows;

  testWidgets(
    'two-page menus preserve playback and page-relative citation history',
    (tester) async {
      final reader = await _Reader.open(tester);
      final paper = PaperSequence(
        reader.session,
        const PaperReadOptions(skipRunningMatter: false),
      );
      await tester.runAsync(() async {
        final passage = (await paper.start())!;
        await reader.narrator.read(
          reader.session,
          () async => NarrationSource(
            documentId: reader.session,
            title: 'Linked paper',
            text: passage.text,
            passage: passage,
            sequence: paper,
          ),
        );
      });
      reader.narrator.setFollowText(true);
      await tester.pump();
      await reader.setTwoPages(true);
      expect(reader.narrator.followText, isTrue);
      expect(reader.speech.playbacks.single.cancelled, isFalse);
      final pages = reader.viewer.layout.pageLayouts;
      expect(pages[0].top, pages[1].top);
      expect(pages[1].left, greaterThan(pages[0].right));
      final spread = pages[0].expandToInclude(pages[1]);
      expect(
        reader.viewer.visibleRect.inflate(.01).contains(spread.topLeft),
        true,
      );
      expect(
        reader.viewer.visibleRect.inflate(.01).contains(spread.bottomRight),
        true,
      );

      // A citation on the right page returns to the same page and zoom even
      // when the context menu changes the layout before Back is pressed.
      await reader.position(2, zoom: 2);
      final origin = reader.viewer.value.clone();
      await reader.clickLink(2);
      expect(reader.viewer.pageNumber, 3);
      expect(reader.narrator.followText, isFalse);
      expect(reader.speech.playbacks.single.cancelled, isFalse);
      await reader.back(reader.mouse);
      _expectMatrix(reader.viewer.value, origin);
      await reader.clickLink(2);
      final returnPoint = reader.session.navigationHistory.previous!;
      await reader.setTwoPages(false);
      final target = reader.viewer.calcMatrixForClampedToNearestBoundary(
        returnPoint.matrixFor(reader.viewer),
        viewSize: reader.viewer.viewSize,
      );
      await reader.back(reader.mouse);
      _expectMatrix(reader.viewer.value, target);
      expect(reader.viewer.pageNumber, 2);
      expect(reader.session.navigationHistory.previous, isNull);
      expect(reader.speech.playbacks.single.cancelled, isFalse);
      expect(reader.container.read(documentErrorProvider), isNull);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(platform),
  );

  testWidgets(
    'citation Back restores nested positions and zoom with the old hover style',
    (tester) async {
      final reader = await _Reader.open(tester);
      final viewer = reader.viewer;
      expect(find.byType(PdfBackButton), findsNothing);
      await reader.position(1, zoom: 2);
      final original = viewer.value.clone();

      // Playback continues, but following must not undo a citation jump.
      final paper = PaperSequence(
        reader.session,
        const PaperReadOptions(skipRunningMatter: false),
      );
      await tester.runAsync(() async {
        final passage = (await paper.start())!;
        await reader.narrator.read(
          reader.session,
          () async => NarrationSource(
            documentId: reader.session,
            title: 'Linked paper',
            text: passage.text,
            passage: passage,
            sequence: paper,
          ),
        );
      });
      reader.narrator.setFollowText(true);
      await tester.pump();
      await reader.position(1, zoom: 2);
      final beforeLink = viewer.value.clone();
      await reader.clickLink(1);
      expect(reader.narrator.followText, false);
      expect(reader.speech.playbacks.single.cancelled, false);
      expect(viewer.pageNumber, 2);
      final citation = viewer.value.clone();
      reader.speech.playbacks.single.events.add(
        const NarrationSnapshot(
          phase: NarrationPhase.playing,
          start: 0,
          end: 4,
        ),
      );
      await tester.pump();
      _expectMatrix(viewer.value, citation);

      final mouse = reader.mouse;
      await mouse.moveTo(
        tester.getBottomRight(find.byType(PdfViewer)) - const Offset(30, 30),
      );
      await tester.pump(const Duration(milliseconds: 120));
      expect(_opacity(tester), 0);
      final corner = tester.getTopLeft(find.byType(PdfViewer));
      await mouse.moveTo(corner + const Offset(2, 2));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      expect(_opacity(tester), 1);
      expect(tester.getSize(find.byType(PdfBackButton)), const Size(60, 60));
      expect(tester.getTopLeft(_back) - corner, const Offset(10, 10));
      expect(tester.widget<shadcn.IconButton>(_back).icon, isA<shadcn.Icon>());
      expect(find.byTooltip('Back'), findsOneWidget);
      await captureReader(tester, 'citation-back-hover');

      // Moving from the hover region onto the button must not oscillate.
      await mouse.moveTo(tester.getCenter(_back));
      await tester.pump(const Duration(milliseconds: 120));
      expect(_opacity(tester), 1);
      await mouse.moveTo(corner + const Offset(100, 100));
      await tester.pump(const Duration(milliseconds: 120));
      expect(_opacity(tester), 0);

      await reader.clickLink(2);
      expect(viewer.pageNumber, 3);
      await reader.back(mouse);
      _expectMatrix(viewer.value, citation);
      await reader.back(mouse);
      _expectMatrix(viewer.value, beforeLink);
      expect(find.byType(PdfBackButton), findsNothing);
      expect(reader.session.navigationHistory.previous, isNull);
      // The narration bar can change viewport height; the earlier view still
      // had the requested zoom, and Back restores the exact pre-click viewport.
      expect(original.entry(0, 0), closeTo(2, .001));

      // Resizing between jump and return retains the reading point and zoom.
      final center = viewer.visibleRect.center;
      final zoom = viewer.currentZoom;
      await reader.clickLink(1);
      tester.view.physicalSize = const Size(1100, 800);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await reader.back(mouse);
      expect((viewer.visibleRect.center - center).distance, lessThan(.01));
      expect(viewer.currentZoom, closeTo(zoom, .001));
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(platform),
  );

  testWidgets(
    'history stays with its tab and Save As, handles interrupted returns and closes cleanly',
    (tester) async {
      final reader = await _Reader.open(tester);
      await reader.position(1, zoom: 2);
      final firstOrigin = reader.viewer.value.clone();
      final first = reader.session;
      await reader.clickLink(1);

      final other = File('${reader.temporary.path}/other.pdf')
        ..writeAsBytesSync(linkedPdfFixture());
      await tester.runAsync(() => reader.documents.addDocument(other.path));
      await reader.ready();
      expect(find.byType(PdfBackButton), findsNothing);
      await reader.position(2, zoom: 1.8);
      final secondOrigin = reader.viewer.value.clone();
      await reader.clickLink(2);
      final second = reader.session;
      expect(identical(first, second), false);
      final copiedPath = '${reader.temporary.path}/renamed.pdf';
      await tester.runAsync(
        () => reader.documents.saveDocument(
          reader.container.read(currentDocumentProvider)!,
          destination: copiedPath,
        ),
      );
      await tester.pump();
      expect(reader.session, same(second));
      expect(second.navigationHistory.previous, isNotNull);

      reader.container.read(currentTabIndexProvider.notifier).state = 0;
      await reader.ready();
      final mouse = reader.mouse;
      await reader.back(mouse);
      _expectMatrix(reader.viewer.value, firstOrigin);
      expect(first.navigationHistory.previous, isNull);
      expect(second.navigationHistory.previous, isNotNull);

      reader.container.read(currentTabIndexProvider.notifier).state = 1;
      await reader.ready();
      await reader.showBack(mouse);
      await reader.click(tester.getCenter(_back));
      await tester.pump();
      expect(tester.widget<shadcn.IconButton>(_back).onPressed, isNull);
      await tester.pump(const Duration(milliseconds: 50));
      // A competing navigation cancels the transition without consuming history.
      await reader.viewer.goToPage(pageNumber: 3, duration: Duration.zero);
      await tester.pump(const Duration(milliseconds: 250));
      expect(second.navigationHistory.previous, isNotNull);
      expect(tester.widget<shadcn.IconButton>(_back).onPressed, isNotNull);
      await reader.back(mouse);
      _expectMatrix(reader.viewer.value, secondOrigin);
      expect(second.navigationHistory.previous, isNull);

      // Same-page destinations also create an exact return point.
      await reader.position(3, zoom: 2);
      final samePage = reader.viewer.value.clone();
      await reader.clickLink(3);
      expect(reader.viewer.pageNumber, 3);
      expect(reader.viewer.value, isNot(samePage));
      await reader.back(mouse);
      _expectMatrix(reader.viewer.value, samePage);

      // Closing in the middle of a jump must not mutate another tab or retain
      // the closed session's history when that path is reopened.
      await reader.position(1, zoom: 2);
      await reader.clickLink(1, settle: false);
      await tester.runAsync(() => reader.documents.removeDocument(second.path));
      await reader.ready();
      expect(reader.session, same(first));
      expect(find.byType(PdfBackButton), findsNothing);
      await tester.runAsync(() => reader.documents.addDocument(copiedPath));
      await reader.ready();
      expect(reader.session, isNot(same(second)));
      expect(reader.session.navigationHistory.previous, isNull);
      expect(find.byType(PdfBackButton), findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(platform),
  );

  testWidgets(
    'invalid destinations do not change history; keyboard Back respects reduced motion',
    (tester) async {
      final reader = await _Reader.open(tester);
      await reader.position(1, zoom: 2);
      final original = reader.viewer.value.clone();
      final handler = tester
          .widget<PdfViewer>(find.byType(PdfViewer))
          .params
          .linkHandlerParams!
          .onLinkTap;
      for (final destination in const [
        PdfDest(0, PdfDestCommand.fit, null),
        PdfDest(99, PdfDestCommand.fit, null),
        PdfDest(1, PdfDestCommand.unknown, null),
        PdfDest(1, PdfDestCommand.xyz, [0, 700, double.nan]),
      ]) {
        handler(PdfLink(const [], dest: destination));
        expect(reader.container.read(documentErrorProvider), isNotNull);
        expect(reader.session.navigationHistory.previous, isNull);
        _expectMatrix(reader.viewer.value, original);
        reader.container.read(documentErrorProvider.notifier).state = null;
      }
      handler(PdfLink(const [], url: Uri.parse('javascript:alert(1)')));
      expect(reader.session.navigationHistory.previous, isNull);
      reader.container.read(documentErrorProvider.notifier).state = null;
      await tester.pump();

      // Two callbacks during one transition cannot create two return points.
      await reader.clickLink(1, settle: false);
      final returnPoint = reader.session.navigationHistory.previous;
      handler(const PdfLink([], dest: PdfDest(3, PdfDestCommand.fit, null)));
      expect(reader.session.navigationHistory.previous, same(returnPoint));
      await tester.pump(const Duration(milliseconds: 250));
      expect(reader.viewer.pageNumber, 2);

      // Enable reduced motion before returning. Focus reveals the same icon
      // without requiring a mouse hover, and Space activates the real button.
      tester.binding.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.binding.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await reader.mouse.moveTo(Offset.zero);
      await tester.pump();
      final buttonContext = tester.element(
        find.descendant(of: _back, matching: find.byType(Icon)),
      );
      Focus.of(buttonContext).requestFocus();
      await tester.pump();
      await tester.pump();
      expect(_opacity(tester), 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      _expectMatrix(reader.viewer.value, original);
      expect(reader.session.navigationHistory.previous, isNull);
      expect(find.byType(PdfBackButton), findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(platform),
  );

  testWidgets(
    'Back remains visible and tappable on touch devices',
    (tester) async {
      var returned = false;
      await tester.pumpWidget(
        shadcn.ShadcnApp(
          home: Align(
            alignment: Alignment.topLeft,
            child: PdfBackButton(onPressed: () => returned = true),
          ),
        ),
      );
      expect(_opacity(tester), 1);
      await tester.tap(_back);
      expect(returned, true);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );
}

final _back = find.byKey(const ValueKey('pdf-link-back'));

double _opacity(WidgetTester tester) => tester
    .widget<AnimatedOpacity>(
      find
          .descendant(
            of: find.byType(PdfBackButton),
            matching: find.byType(AnimatedOpacity),
          )
          .first,
    )
    .opacity;

void _expectMatrix(Matrix4 actual, Matrix4 expected) {
  for (var i = 0; i < 16; i++) {
    expect(
      actual.storage[i],
      closeTo(expected.storage[i], .01),
      reason: 'matrix element $i',
    );
  }
}

class _Reader {
  _Reader(
    this.tester,
    this.temporary,
    this.container,
    this.narrator,
    this.speech,
  );
  final WidgetTester tester;
  final Directory temporary;
  final ProviderContainer container;
  final NarrationController narrator;
  final FakeNarratorSession speech;
  late final TestGesture mouse;
  PdfViewerController get viewer => container.read(pdfViewerControllerProvider);
  PdfSession get session => container.read(currentDocumentProvider)!.session;
  LoadedDocumentsNotifier get documents =>
      container.read(loadedDocumentsProvider.notifier);

  static Future<_Reader> open(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      await (FontLoader('Urbanist')..addFont(
            rootBundle.load(
              'assets/fonts/Urbanist/static/Urbanist-Regular.ttf',
            ),
          ))
          .load();
    });
    final temporary = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('podofo-link-back-'),
    ))!;
    await tester.runAsync(() => pdfrxInitialize(tmpPath: temporary.path));
    final file = File('${temporary.path}/citations.pdf')
      ..writeAsBytesSync(linkedPdfFixture());
    final store = Store(getObjectBoxModel(), directory: '${temporary.path}/db');
    store.box<DocumentEntity>().put(DocumentEntity(filePath: file.path));
    final speech = FakeNarratorSession();
    final narrator = NarrationController(open: (_) async => speech);
    final container = ProviderContainer(
      overrides: [
        objectboxProvider.overrideWithValue(ObjectBox(store)),
        narrationControllerProvider.overrideWithValue(narrator),
      ],
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(narrator.close);
      container.dispose();
      store.close();
      await tester.runAsync(() async {
        await PdfrxEntryFunctions.instance.stopBackgroundWorker();
        await temporary.delete(recursive: true);
      });
    });
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('reader-capture'),
        child: UncontrolledProviderScope(
          container: container,
          child: const MyApp(),
        ),
      ),
    );
    final reader = _Reader(tester, temporary, container, narrator, speech);
    reader.mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await reader.mouse.addPointer(location: Offset.zero);
    addTearDown(reader.mouse.removePointer);
    await reader.ready();
    return reader;
  }

  Future<void> ready() async {
    await waitForNative(
      tester,
      () =>
          container.read(pdfTextSearcherProvider) != null &&
          container.read(currentDocumentProvider)?.session.annotationsReady ==
              true,
    );
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> position(int pageNumber, {required double zoom}) async {
    final page = viewer.layout.pageLayouts[pageNumber - 1];
    await viewer.goTo(
      viewer.calcMatrixFor(page.center, zoom: zoom),
      duration: Duration.zero,
    );
    await tester.pump();
    // Give the native page/link loader a chance to install hit targets.
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  Future<void> setTwoPages(bool enabled) async {
    await tester.tapAt(
      tester.getTopLeft(find.byType(PdfViewer)) + const Offset(4, 4),
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    final label = enabled ? 'Two pages' : 'Single page';
    await waitForNative(tester, () => find.text(label).evaluate().isNotEmpty);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text(label));
    await waitForNative(
      tester,
      () => (viewer.params.layoutPages != null) == enabled,
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(PdfSelectionMenu), findsNothing);
  }

  Future<void> clickLink(int pageNumber, {bool settle = true}) async {
    final page = session.lease.document.pages[pageNumber - 1];
    final links = (await tester.runAsync(
      () => session.lease.use((_) => page.loadLinks()),
    ))!;
    final rect = links.single.rects.single.toRectInDocument(
      page: page,
      pageRect: viewer.layout.pageLayouts[pageNumber - 1],
    );
    final point = viewer.documentToGlobal(rect.center)!;
    expect(tester.getRect(find.byType(PdfViewer)).contains(point), true);
    final previous = session.navigationHistory.previous;
    await click(point);
    // Published pdfrx waits for its double-tap timeout before dispatching a
    // link tap. Observe dispatch before advancing the app's link animation;
    // this also works with the optional reduced-tap-delay dependency fix.
    await waitForNative(
      tester,
      () => !identical(session.navigationHistory.previous, previous),
    );
    await tester.pump();
    if (settle) {
      await tester.pump(const Duration(milliseconds: 250));
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
    }
  }

  Future<void> showBack(TestGesture mouse) async {
    await mouse.moveTo(
      tester.getTopLeft(find.byType(PdfViewer)) + const Offset(2, 2),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
  }

  Future<void> back(TestGesture mouse) async {
    await showBack(mouse);
    await click(tester.getCenter(_back));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();
  }

  Future<void> click(Offset point) async {
    await mouse.moveTo(point);
    await mouse.down(point);
    await tester.pump(const Duration(milliseconds: 20));
    await mouse.up();
    await tester.pump();
  }
}
