import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' as flutter;
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:podofo_one/src/widgets/components/pdf_context_menu_overlay.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

const _captureKey = ValueKey('capture');
const _pageKey = ValueKey('page');
const _swatchKey = ValueKey('swatch');

Widget _app({
  required ColorScheme colors,
  required double strength,
  required bool invert,
  bool showMenu = true,
  bool deferEntrance = false,
  bool contentReady = true,
  Widget? menu,
}) {
  final bias = 255 * (1 + strength) / 2;
  // A portable image filter exercises the same compositing boundary as the
  // PDF shader, including partial inversion, without requiring Impeller.
  final filter = ColorFilter.matrix([
    ...[-strength, 0, 0, 0, bias],
    ...[0, -strength, 0, 0, bias],
    ...[0, 0, -strength, 0, bias],
    ...[0, 0, 0, 1, 0],
  ]);
  return RepaintBoundary(
    key: _captureKey,
    child: ShadcnApp(
      home: Padding(
        padding: const EdgeInsets.fromLTRB(50, 72, 50, 30),
        child: Theme(
          data: ThemeData(colorScheme: colors),
          child: ImageFiltered(
            enabled: invert,
            imageFilter: filter,
            child: ColoredBox(
              key: _pageKey,
              color: const Color(0xffffffff),
              child: PdfContextMenuOverlay(
                anchor: showMenu ? const Offset(100, 120) : null,
                deferEntrance: deferEntrance,
                child: !showMenu
                    ? null
                    : Builder(
                        builder: (context) {
                          if (!contentReady) return const SizedBox.shrink();
                          PdfContextMenuOverlay.markContentReady(context);
                          return menu ??
                              MenuPopup(
                                children: [
                                  SizedBox(
                                    width: 160,
                                    height: 40,
                                    child: Align(
                                      alignment: Alignment.centerLeft,
                                      child: ColoredBox(
                                        key: _swatchKey,
                                        color: const Color(0xffff0000),
                                        child: const SizedBox(
                                          width: 16,
                                          height: 16,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              );
                        },
                      ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('reduced motion shows and removes the menu immediately', (
    tester,
  ) async {
    Widget app(bool show) => ShadcnApp(
      home: MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: PdfContextMenuOverlay(
          anchor: const Offset(100, 120),
          child: show
              ? const SizedBox(key: _swatchKey, width: 160, height: 40)
              : null,
        ),
      ),
    );
    await tester.pumpWidget(app(true));
    final fade = tester.widget<FadeTransition>(
      find
          .ancestor(
            of: find.byKey(_swatchKey),
            matching: find.byType(FadeTransition),
          )
          .first,
    );
    expect(fade.opacity.value, 1);
    await tester.pumpWidget(app(false));
    expect(find.byKey(_swatchKey), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('page menu matches dropdown entrance and exit frames', (
    tester,
  ) async {
    final visible = ValueNotifier(false);
    addTearDown(visible.dispose);
    late BuildContext dropdownContext;
    const pageMenuKey = ValueKey('page-menu');
    const dropdownKey = ValueKey('margin-menu');
    Widget menu(Key key) =>
        MenuPopup(key: key, children: const [SizedBox(width: 160, height: 40)]);
    await tester.pumpWidget(
      ShadcnApp(
        home: Builder(
          builder: (context) {
            dropdownContext = context;
            return ValueListenableBuilder(
              valueListenable: visible,
              builder: (context, show, _) => PdfContextMenuOverlay(
                anchor: const Offset(80, 100),
                child: show ? menu(pageMenuKey) : null,
              ),
            );
          },
        ),
      ),
    );
    final dropdown = showDropdown<void>(
      context: dropdownContext,
      position: const Offset(400, 100),
      alignment: Alignment.topLeft,
      follow: false,
      offset: Offset.zero,
      margin: EdgeInsets.zero,
      allowInvertHorizontal: false,
      allowInvertVertical: false,
      builder: (_) => menu(dropdownKey),
    );
    visible.value = true;
    await tester.pump();
    await tester.pump();
    double opacity(Key key) => tester
        .widget<FadeTransition>(
          find
              .ancestor(
                of: find.byKey(key),
                matching: find.byType(FadeTransition),
              )
              .first,
        )
        .opacity
        .value;
    Rect paintedRect(Key key) {
      final box = tester.renderObject<RenderBox>(find.byKey(key));
      return MatrixUtils.transformRect(
        box.getTransformTo(null),
        Offset.zero & box.size,
      );
    }

    void expectMatchingFrames() {
      expect(opacity(pageMenuKey), closeTo(opacity(dropdownKey), 0.001));
      expect(
        paintedRect(pageMenuKey).width,
        closeTo(paintedRect(dropdownKey).width, 0.01),
      );
      expect(paintedRect(pageMenuKey).topLeft, const Offset(80, 100));
    }

    expect(opacity(pageMenuKey), 0);
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 25));
      expectMatchingFrames();
      if (i == 1) expect(opacity(pageMenuKey), closeTo(0.5, 0.001));
    }
    expect(opacity(pageMenuKey), 1);
    visible.value = false;
    unawaited(dropdown.close());
    await tester.pump();
    await tester.pump();
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 25));
      expectMatchingFrames();
      if (i == 1) expect(opacity(pageMenuKey), closeTo(0.5, 0.001));
    }
    await tester.pumpAndSettle();
    expect(find.byKey(pageMenuKey), findsNothing);
    expect(find.byKey(dropdownKey), findsNothing);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(flutter.TargetPlatform.windows));

  testWidgets(
    'closing menu ignores input and can reopen before exit completes',
    (tester) async {
      var taps = 0;
      final focus = FocusNode();
      addTearDown(focus.dispose);
      Widget app({bool show = true}) => _app(
        colors: ColorSchemes.lightZinc,
        strength: 1,
        invert: false,
        showMenu: show,
        menu: Focus(
          focusNode: focus,
          autofocus: true,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => taps++,
            child: const SizedBox(key: _swatchKey, width: 160, height: 40),
          ),
        ),
      );
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(focus.hasFocus, isTrue);
      final point = tester.getCenter(find.byKey(_swatchKey));
      await tester.tapAt(point);
      expect(taps, 1);
      await tester.pumpWidget(app(show: false));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byKey(_swatchKey), findsOneWidget);
      expect(focus.hasFocus, isFalse);
      await tester.tapAt(point);
      expect(taps, 1);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(find.byKey(_swatchKey), findsOneWidget);
      expect(focus.hasFocus, isTrue);
      await tester.tapAt(point);
      expect(taps, 2);
      await tester.pumpWidget(app(show: false));
      await tester.pump(const Duration(milliseconds: 25));
      // Closing a document/window must also dispose an in-flight transition.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'annotation loading defers entrance and cannot revive a dismissed menu',
    (tester) async {
      Widget app({bool ready = false, bool show = true}) => _app(
        colors: ColorSchemes.lightZinc,
        strength: 1,
        invert: false,
        showMenu: show,
        deferEntrance: true,
        contentReady: ready,
      );
      await tester.pumpWidget(app());
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(MenuPopup), findsNothing);
      await tester.pumpWidget(app(ready: true));
      await tester.pump();
      final fade = find
          .ancestor(
            of: find.byType(MenuPopup),
            matching: find.byType(FadeTransition),
          )
          .first;
      expect(tester.widget<FadeTransition>(fade).opacity.value, 0);
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        tester.widget<FadeTransition>(fade).opacity.value,
        closeTo(0.5, 0.001),
      );
      await tester.pumpAndSettle();
      await tester.pumpWidget(app(show: false));
      await tester.pumpAndSettle();
      await tester.pumpWidget(app());
      await tester.pumpWidget(app(show: false));
      await tester.pumpWidget(app(ready: true, show: false));
      await tester.pumpAndSettle();
      expect(find.byType(MenuPopup), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('menu retains theme and swatch colors outside PDF inversion', (
    tester,
  ) async {
    for (final mode in [
      (colors: ColorSchemes.lightZinc, strength: 1.0, invert: false),
      (colors: ColorSchemes.darkZinc, strength: 1.0, invert: true),
      (colors: ColorSchemes.darkZinc, strength: 0.4, invert: true),
      (colors: ColorSchemes.darkZinc, strength: 1.0, invert: false),
      (colors: ColorSchemes.lightZinc, strength: 1.0, invert: false),
    ]) {
      await tester.pumpWidget(
        _app(colors: mode.colors, strength: mode.strength, invert: mode.invert),
      );
      await tester.pumpAndSettle();
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(_captureKey),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        try {
          final bytes = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          Color pixelAt(Offset global) {
            final point = boundary.globalToLocal(global);
            final index =
                (point.dy.floor() * image.width + point.dx.floor()) * 4;
            return Color.fromARGB(
              bytes.getUint8(index + 3),
              bytes.getUint8(index),
              bytes.getUint8(index + 1),
              bytes.getUint8(index + 2),
            );
          }

          final menu = tester.getRect(find.byType(MenuPopup));
          expect(
            pixelAt(menu.centerRight - const Offset(8, 0)),
            mode.colors.popover,
          );
          expect(
            pixelAt(tester.getCenter(find.byKey(_swatchKey))),
            const Color(0xffff0000),
          );
          final page = pixelAt(
            tester.getTopLeft(find.byKey(_pageKey)) + const Offset(8, 8),
          );
          final expected = mode.invert ? (1 - mode.strength) / 2 : 1.0;
          expect(page.r, closeTo(expected, 1 / 255));
          expect(page.g, closeTo(expected, 1 / 255));
          expect(page.b, closeTo(expected, 1 / 255));
        } finally {
          image.dispose();
        }
      });
    }
    await tester.pumpWidget(
      _app(
        colors: ColorSchemes.darkZinc,
        strength: 1,
        invert: true,
        showMenu: false,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(MenuPopup), findsNothing);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(flutter.TargetPlatform.windows));
}
