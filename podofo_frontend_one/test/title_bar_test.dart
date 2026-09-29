import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:podofo_one/src/providers/document_provider.dart';
import 'package:podofo_one/src/providers/ui_provider.dart';
import 'package:podofo_one/src/services/windows_title_bar.dart';
import 'package:podofo_one/src/widgets/areas/title_bar.dart' as app;
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;
import 'package:window_manager/window_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('window_manager');
  final calls = <String>[];
  var maximized = false;

  setUp(() {
    calls.clear();
    maximized = false;
    WindowsTitleBar.instance.value = const WindowsTitleBarMetrics();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('podofo/windows_title_bar'),
          (call) async => null,
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          if (call.method == 'isMaximized') return maximized;
          if (call.method == 'isFullScreen') return false;
          return null;
        });
  });

  tearDown(() {
    WindowsTitleBar.instance.value = const WindowsTitleBarMetrics();
  });

  Future<void> pumpTitleBar(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [currentDocumentProvider.overrideWithValue(null)],
        child: shadcn.ShadcnApp(
          localizationsDelegates: const [DefaultMaterialLocalizations.delegate],
          builder: (context, child) => Theme(
            data: ThemeData(),
            child: Material(child: child),
          ),
          home: const app.TitleBar(child: SizedBox()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    calls.clear();
  }

  testWidgets('double clicking blank title bar maximizes and restores', (
    tester,
  ) async {
    await pumpTitleBar(tester);
    for (final wasMaximized in [false, true]) {
      maximized = wasMaximized;
      calls.clear();
      await tester.tapAt(const Offset(200, 16));
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tapAt(const Offset(200, 16));
      await tester.pumpAndSettle();
      expect(calls, contains(wasMaximized ? 'unmaximize' : 'maximize'));
      expect(calls, isNot(contains('startDragging')));
      await tester.pump(const Duration(milliseconds: 500));
    }
  });

  testWidgets('native caption bounds replace the simulated buttons', (
    tester,
  ) async {
    WindowsTitleBar.instance.value = const WindowsTitleBarMetrics(
      native: true,
      height: 35,
      buttonsWidth: 142,
    );
    await pumpTitleBar(tester);
    expect(find.byType(WindowCaption), findsNothing);
    expect(find.byType(WindowCaptionButton), findsNothing);
    expect(tester.getTopLeft(find.text('File')).dy, greaterThanOrEqualTo(0));
    final captionSpace = find.byWidgetPredicate(
      (widget) => widget is SizedBox && widget.width == 142,
    );
    expect(captionSpace, findsOneWidget);
    expect(tester.getBottomRight(captionSpace).dx, 800);
    WindowsTitleBar.instance.value = const WindowsTitleBarMetrics(
      native: true,
      height: 32,
      buttonsWidth: 138,
    );
    await tester.pumpAndSettle();
    expect(captionSpace, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('right clicking blank title bar opens the Windows system menu', (
    tester,
  ) async {
    await pumpTitleBar(tester);
    final mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await mouse.down(const Offset(200, 16));
    await mouse.up();
    await tester.pumpAndSettle();
    expect(calls, ['popUpWindowMenu']);
  }, skip: !Platform.isWindows);

  testWidgets(
    'title bar still drags and interactive content keeps its clicks',
    (tester) async {
      await pumpTitleBar(tester);
      await tester.dragFrom(const Offset(200, 16), const Offset(80, 0));
      await tester.pumpAndSettle();
      expect(calls, contains('startDragging'));
      calls.clear();
      final recentFiles = find.bySemanticsLabel('Recent files');
      expect(tester.getSize(recentFiles), const Size(200, 15));
      await tester.tap(recentFiles);
      await tester.pumpAndSettle();
      final context = tester.element(find.byType(app.TitleBar));
      expect(
        ProviderScope.containerOf(context).read(commandPaletteProvider),
        isTrue,
      );
      expect(calls, isEmpty);
      await tester.tap(find.text('File'));
      await tester.pumpAndSettle();
      expect(find.text('Open PDF…'), findsOneWidget);
      expect(calls, isEmpty);
    },
  );
}
