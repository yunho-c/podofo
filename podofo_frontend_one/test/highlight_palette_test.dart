import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:podofo_one/objectbox.g.dart';
import 'package:podofo_one/src/data/objectbox.dart';
import 'package:podofo_one/src/providers/data_provider.dart';
import 'package:podofo_one/src/providers/user_state_provider.dart';
import 'package:podofo_one/src/widgets/components/highlight_palette.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

void main() {
  testWidgets(
    'palette shows opaque hues in both themes but retains annotation alpha',
    (tester) async {
      final temporary = Directory.systemTemp.createTempSync('podofo-palette-');
      final store = Store(getObjectBoxModel(), directory: temporary.path);
      store.box<UserState>().put(UserState()..highlightColor = '#663366cc');
      final container = ProviderContainer(
        overrides: [objectboxProvider.overrideWithValue(ObjectBox(store))],
      );
      const captureKey = ValueKey('palette-capture');
      String? chosen;
      try {
        for (final colors in [ColorSchemes.lightZinc, ColorSchemes.darkZinc]) {
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: RepaintBoundary(
                key: captureKey,
                child: ShadcnApp(
                  theme: ThemeData(colorScheme: colors),
                  home: Center(
                    child: MenuPopup(
                      children: [
                        HighlightPalette(
                          showCustom: true,
                          onSelected: (color) => chosen = color,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final state = container.read(userStateNotifierProvider);
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(captureKey),
          );
          await tester.runAsync(() async {
            final image = await boundary.toImage();
            try {
              final bytes = (await image.toByteData(
                format: ui.ImageByteFormat.rawRgba,
              ))!;
              int pixelAt(Offset point) {
                final local = boundary.globalToLocal(point);
                final index =
                    (local.dy.floor() * image.width + local.dx.floor()) * 4;
                return Color.fromARGB(
                  bytes.getUint8(index + 3),
                  bytes.getUint8(index),
                  bytes.getUint8(index + 1),
                  bytes.getUint8(index + 2),
                ).toARGB32();
              }

              for (var i = 0; i < state.highlightColorPalette.length; i++) {
                final expected =
                    int.parse(
                      state.highlightColorPalette[i].substring(1),
                      radix: 16,
                    ) |
                    0xff000000;
                expect(
                  pixelAt(
                    tester.getCenter(
                      find.byKey(ValueKey('highlight-color-$i')),
                    ),
                  ),
                  expected,
                );
              }
              expect(
                pixelAt(
                  tester.getCenter(
                    find.byKey(const ValueKey('highlight-custom-color')),
                  ),
                ),
                0xff3366cc,
              );
              final png = (await image.toByteData(
                format: ui.ImageByteFormat.png,
              ))!;
              final file = File(
                'build/test-artifacts/highlight-palette-${colors.brightness.name}.png',
              );
              await file.parent.create(recursive: true);
              await file.writeAsBytes(png.buffer.asUint8List());
            } finally {
              image.dispose();
            }
          });
        }
        await tester.tap(find.byKey(const ValueKey('highlight-color-2')));
        await tester.pumpAndSettle();
        expect(chosen, '#66ffeb3b');
        expect(
          container.read(userStateNotifierProvider).highlightColor,
          chosen,
        );
        expect(store.box<UserState>().getAll().single.highlightColor, chosen);
        await tester.tap(find.byKey(const ValueKey('highlight-custom-color')));
        // The picker's focused hex field has a blinking cursor.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        final picker = tester.widget<ColorPicker>(find.byType(ColorPicker));
        expect(picker.showAlpha, isTrue);
        expect(picker.value.toColor().toARGB32(), 0x66ffeb3b);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
        store.close();
        temporary.deleteSync(recursive: true);
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );
}
