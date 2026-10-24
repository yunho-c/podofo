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
              child: showMenu
                  ? PdfContextMenuOverlay(
                      anchor: const Offset(100, 120),
                      child: MenuPopup(
                        children: [
                          SizedBox(
                            width: 160,
                            height: 40,
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: ColoredBox(
                                key: _swatchKey,
                                color: const Color(0xffff0000),
                                child: const SizedBox(width: 16, height: 16),
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                  : const SizedBox.expand(),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
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
