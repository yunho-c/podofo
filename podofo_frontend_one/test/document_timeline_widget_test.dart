import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart' as m;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:podofo_one/src/narration/narration_controller.dart';
import 'package:podofo_one/src/narration/narrator.dart';
import 'package:podofo_one/src/widgets/components/document_narration_timeline.dart';

import 'document_seek_test.dart' as seek;
import 'paper_index_test.dart' as fixture;
import 'paper_timeline_test.dart' as timings;

Future<void> mount(
  WidgetTester tester,
  NarrationController controller, {
  double width = 600,
  bool developerMode = false,
}) async {
  await tester.pumpWidget(
    ShadcnApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        typography: const Typography.geist().copyWith(
          sans: () => const TextStyle(fontFamily: 'Urbanist'),
        ),
        colorScheme: ColorSchemes.lightZinc,
      ),
      localizationsDelegates: const [m.DefaultMaterialLocalizations.delegate],
      builder: (_, child) => m.Theme(
        data: m.ThemeData(fontFamily: 'Urbanist'),
        child: m.Material(type: m.MaterialType.transparency, child: child),
      ),
      home: Center(
        child: RepaintBoundary(
          key: const ValueKey('timeline-capture'),
          child: ColoredBox(
            color: const Color(0xFFFFFFFF),
            child: SizedBox(
              width: width,
              child: ListenableBuilder(
                listenable: controller,
                builder: (_, _) => DocumentNarrationTimeline(
                  controller: controller,
                  developerMode: developerMode,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

m.Slider slider(WidgetTester tester) => tester.widget<m.Slider>(
  find.byKey(const ValueKey('document-narration-timeline')),
);
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.runAsync(timings.settle);
    await tester.pump(const Duration(milliseconds: 1));
  }
}

void main() {
  setUpAll(() async {
    await (FontLoader('Urbanist')..addFont(
          rootBundle.load('assets/fonts/Urbanist/static/Urbanist-Regular.ttf'),
        ))
        .load();
  });
  testWidgets(
    'one seek on release; frozen scale survives measured prefix correction',
    (tester) async {
      final paper = fixture.sequence(3), session = seek.SeekSession();
      final controller = (await tester.runAsync(
        () => seek.reader(paper, session),
      ))!;
      addTearDown(controller.close);
      await mount(tester, controller);
      slider(tester).onChangeStart!(15000000);
      slider(tester).onChanged!(15000000);
      await tester.pump();
      expect(session.playbacks.length, 1);
      expect(find.textContaining('Seek to 0:15'), findsOneWidget);
      final descriptor = paper.index.page(1)!.passages.single;
      paper.timeline.record(
        descriptor,
        timings.timing(session.texts.first, frames: 2000, actual: true),
      );
      await tester.pump();
      expect(slider(tester).max, 30000000);
      slider(tester).onChangeEnd!(15000000);
      await settle(tester);
      expect(session.playbacks.length, 2);
      expect(
        paper.pageNumber,
        2,
        reason:
            '${controller.status}; frame=${session.playbacks.last.lastSeek}, native=${controller.snapshot?.positionFrames}, pending=${controller.seekingDocument}',
      );
      expect(session.playbacks.last.lastSeek, 500);
      expect(controller.documentPosition!.microseconds, 25000000);
      expect(slider(tester).max, 40000000);
      expect(tester.takeException(), isNull);
    },
  );

  for (final destination in [5000000.0, 15000000.0]) {
    testWidgets('thumb holds $destination until native seek confirmation', (
      tester,
    ) async {
      final paper = fixture.sequence(3), session = seek.SeekSession();
      final controller = (await tester.runAsync(
        () => seek.reader(paper, session),
      ))!;
      addTearDown(controller.close);
      session.confirmSeek = false;
      (session.playbacks.single as seek.TimedPlayback).confirmSeek = false;
      await mount(tester, controller);
      final previous = controller.documentPosition!.microseconds;
      slider(tester).onChangeStart!(destination);
      slider(tester).onChanged!(destination);
      await tester.pump();
      slider(tester).onChangeEnd!(destination);
      await tester.pump();
      expect(slider(tester).value, destination);
      await settle(tester);
      expect(controller.seekingDocument, true);
      expect(controller.documentPosition!.microseconds, previous);
      expect(paper.pageNumber, 1);
      expect(slider(tester).value, destination);

      final playback = session.playbacks.last as seek.TimedPlayback;
      playback.position = playback.lastSeek!;
      playback.state(NarrationPhase.paused);
      await settle(tester);
      expect(controller.seekingDocument, false);
      expect(slider(tester).value, destination);
      expect(controller.documentPosition!.microseconds, destination.toInt());
    });
  }

  testWidgets(
    'scrubbing previews cached text without extraction or playback changes',
    (tester) async {
      final paper = fixture.sequence(3), session = seek.SeekSession();
      final controller = (await tester.runAsync(
        () => seek.reader(paper, session),
      ))!;
      addTearDown(controller.close);
      await mount(tester, controller);
      final source = controller.source, anchor = controller.currentAnchor;
      final position = controller.documentPosition!.microseconds;
      final extractions = paper.planner.extractionCount;
      final cachedPages = paper.cachedPageCount;
      var playbackNotifications = 0;
      controller.addListener(() => playbackNotifications++);
      slider(tester).onChangeStart!(5000000);
      slider(tester).onChanged!(5000000);
      await tester.pump();
      expect(controller.previewingDocument, true);
      final preview = controller.previewHighlight!;
      expect(
        preview.passage.rectangles(1, preview.start, preview.end),
        isNotEmpty,
      );
      expect(controller.source, same(source));
      expect(controller.currentAnchor, same(anchor));
      expect(controller.documentPosition!.microseconds, position);
      expect(playbackNotifications, 0);
      expect(session.playbacks, hasLength(1));
      expect(session.playbacks.single.lastSeek, isNull);

      // Indexed timing alone does not authorize loading uncached page geometry.
      slider(tester).onChanged!(25000000);
      await tester.pump();
      expect(controller.previewingDocument, true);
      expect(controller.previewHighlight, isNull);
      expect(paper.planner.extractionCount, extractions);
      expect(paper.cachedPageCount, cachedPages);
      slider(tester).onChanged!(5000000);
      await tester.pump();
      expect(controller.previewHighlight, isNotNull);
      session.confirmSeek = false;
      (session.playbacks.single as seek.TimedPlayback).confirmSeek = false;
      slider(tester).onChangeEnd!(5000000);
      await settle(tester);
      expect(controller.scrubPreview.value, isNull);
      expect(controller.previewHighlight, isNotNull);
      await tester.runAsync(controller.stop);
      await settle(tester);
      expect(controller.previewingDocument, false);
      expect(controller.previewHighlight, isNull);
    },
  );

  testWidgets(
    'pending preview follows the latest seek and clears on failure or Stop',
    (tester) async {
      final paper = fixture.sequence(3), session = seek.SeekSession();
      final controller = (await tester.runAsync(
        () => seek.reader(paper, session),
      ))!;
      addTearDown(controller.close);
      session.confirmSeek = false;
      await mount(tester, controller);
      final previous = slider(tester).value;
      for (final destination in [15000000.0, 25000000.0]) {
        slider(tester).onChangeStart!(destination);
        slider(tester).onChanged!(destination);
        slider(tester).onChangeEnd!(destination);
        await settle(tester);
        expect(slider(tester).value, destination);
        expect(controller.seekingDocument, true);
      }
      await tester.pump(const Duration(seconds: 31));
      await settle(tester);
      expect(controller.error, contains('too long'));
      expect(slider(tester).value, previous);
      slider(tester).onChangeStart!(15000000);
      slider(tester).onChanged!(15000000);
      slider(tester).onChangeEnd!(15000000);
      await settle(tester);
      expect(slider(tester).value, 15000000);
      await tester.runAsync(controller.stop);
      await settle(tester);
      expect(slider(tester).value, previous);
    },
  );

  testWidgets(
    'partial coverage disables document seeking and shows its limits',
    (tester) async {
      final paper = fixture.sequence(3), session = seek.SeekSession();
      final controller = (await tester.runAsync(
        () => seek.reader(paper, session),
      ))!;
      addTearDown(controller.close);
      paper.index.fail(2, StateError('Review page'));
      await mount(tester, controller, width: 360);
      expect(slider(tester).onChanged, isNull);
      expect(find.textContaining('Partial document duration'), findsOneWidget);
      expect(find.textContaining('1 unresolved page'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('timeline-capture')),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        try {
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File(
            'build/document-timeline-qualification/milestone5/partial-360.png',
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
        } finally {
          image.dispose();
        }
      });
    },
  );

  testWidgets('failed interval preserves playback; seeking beyond it works', (
    tester,
  ) async {
    final paper = fixture.sequence(3), session = seek.SeekSession();
    session.failText = fixture.page(2).text.text;
    final controller = (await tester.runAsync(
      () => seek.reader(paper, session),
    ))!;
    addTearDown(controller.close);
    await mount(tester, controller, width: 360);
    expect(slider(tester).onChanged, isNotNull);
    expect(slider(tester).max, 30000000);
    expect(find.textContaining('rough timing'), findsNothing);
    expect(find.text('Retry duration planning'), findsNothing);
    slider(tester).onChangeStart!(15000000);
    slider(tester).onChanged!(15000000);
    await tester.pump();
    expect(find.textContaining('Timing unavailable on page 2'), findsOneWidget);
    slider(tester).onChangeEnd!(15000000);
    await settle(tester);
    expect(session.playbacks.length, 1);
    expect(session.playbacks.single.disposed, false);
    expect(paper.pageNumber, 1);
    expect(find.textContaining('Timing unavailable on page 2'), findsOneWidget);
    slider(tester).onChangeStart!(25000000);
    slider(tester).onChanged!(25000000);
    slider(tester).onChangeEnd!(25000000);
    await settle(tester);
    expect(paper.pageNumber, 3);
    expect(session.playbacks.last.lastSeek, 500);
    expect(controller.documentPosition!.microseconds, 25000000);
    expect(controller.documentPosition!.approximate, true);
    expect(find.textContaining('Timing unavailable on page 2'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'developer mode reveals the diagnostic row with retry on the right',
    (tester) async {
      final paper = fixture.sequence(3), session = seek.SeekSession();
      session.failText = fixture.page(2).text.text;
      final controller = (await tester.runAsync(
        () => seek.reader(paper, session),
      ))!;
      addTearDown(controller.close);
      await mount(tester, controller, width: 360, developerMode: true);
      final message = find.byKey(const ValueKey('document-timeline-fallback'));
      final retry = find.text('Retry duration planning');
      expect(message, findsOneWidget);
      expect(retry, findsOneWidget);
      expect(
        tester.getRect(retry).left,
        greaterThan(tester.getRect(message).right),
      );
      expect(tester.takeException(), isNull);
      await mount(tester, controller, width: 360);
      expect(
        find.byKey(const ValueKey('document-timeline-diagnostics')),
        findsNothing,
      );
      expect(retry, findsNothing);
      expect(slider(tester).onChanged, isNotNull);
      await mount(tester, controller, width: 360, developerMode: true);
      session.failText = null;
      await tester.tap(retry);
      await settle(tester);
      expect(paper.timeline.snapshot.failedPassages, 0);
      expect(
        find.byKey(const ValueKey('document-timeline-diagnostics')),
        findsNothing,
      );
    },
  );

  testWidgets('settings invalidate an ongoing drag; keyboard remains usable', (
    tester,
  ) async {
    final paper = fixture.sequence(3), session = seek.SeekSession();
    final controller = (await tester.runAsync(
      () => seek.reader(paper, session),
    ))!;
    addTearDown(controller.close);
    await mount(tester, controller);
    slider(tester).onChangeStart!(15000000);
    slider(tester).onChanged!(15000000);
    await tester.runAsync(
      () => controller.configure(const NarrationSettings(speed: 1.3)),
    );
    await settle(tester);
    final count = session.playbacks.length;
    slider(tester).onChanged!(25000000);
    slider(tester).onChangeEnd!(25000000);
    await settle(tester);
    expect(session.playbacks.length, count);
    expect(paper.pageNumber, 1);
    slider(tester).focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await settle(tester);
    expect(controller.documentPosition!.microseconds, greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Stop cancels a drag without resuming speech', (tester) async {
    final paper = fixture.sequence(3), session = seek.SeekSession();
    final controller = (await tester.runAsync(
      () => seek.reader(paper, session),
    ))!;
    addTearDown(controller.close);
    await mount(tester, controller);
    slider(tester).onChangeStart!(15000000);
    slider(tester).onChanged!(15000000);
    await tester.runAsync(controller.stop);
    await settle(tester);
    slider(tester).onChanged!(25000000);
    slider(tester).onChangeEnd!(25000000);
    await settle(tester);
    expect(session.playbacks.length, 1);
    expect(paper.pageNumber, 1);
    expect(controller.snapshot!.phase, NarrationPhase.stopped);
  });

  testWidgets('pointer drag previews without seeking until release', (
    tester,
  ) async {
    final paper = fixture.sequence(3), session = seek.SeekSession();
    final controller = (await tester.runAsync(
      () => seek.reader(paper, session),
    ))!;
    addTearDown(controller.close);
    await mount(tester, controller);
    final rect = tester.getRect(
      find.byKey(const ValueKey('document-narration-timeline')),
    );
    final gesture = await tester.startGesture(
      Offset(rect.left + 40, rect.center.dy),
    );
    await gesture.moveTo(Offset(rect.right - 40, rect.center.dy));
    await tester.pump();
    expect(session.playbacks.length, 1);
    expect(find.textContaining('Seek to'), findsOneWidget);
    await gesture.up();
    await settle(tester);
    expect(session.playbacks.length, 2);
    expect(
      paper.pageNumber,
      3,
      reason:
          '${controller.status}; frame=${session.playbacks.last.lastSeek}, native=${controller.snapshot?.positionFrames}, pending=${controller.seekingDocument}',
    );
  });

  test('long document clock and zero duration formatting', () {
    expect(documentClock(0), '0:00');
    expect(documentClock(3661000000), '1:01:01');
  });

  testWidgets('complete hour-scale timeline fits at narrow width after Stop', (
    tester,
  ) async {
    final paper = fixture.sequence(3), session = seek.SeekSession();
    final controller = (await tester.runAsync(
      () => seek.reader(paper, session),
    ))!;
    addTearDown(controller.close);
    await tester.runAsync(controller.stop);
    for (var page = 1; page <= 3; page++) {
      final descriptor = paper.index.page(page)!.passages.single;
      final passage = (await tester.runAsync(() => paper.preview(page)))!
          .passages
          .single;
      paper.timeline.record(
        descriptor,
        timings.timing(passage.text, frames: 400000),
      );
    }
    await mount(tester, controller, width: 360);
    expect(slider(tester).onChanged, isNotNull);
    expect(find.textContaining('3:20:00'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('timeline-capture')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File(
          'build/document-timeline-qualification/milestone6/complete-360.png',
        );
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });
  });
}
