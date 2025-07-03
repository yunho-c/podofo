import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'package:podofo_one/src/providers/providers.dart';

class DarkModeButton extends ConsumerWidget {
  const DarkModeButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentTheme = ref.watch(themeModeProvider);

    return GestureDetector(
      onSecondaryTapUp: (details) {
        showDropdown(
          context: context,
          position: details.globalPosition,
          builder: (context) {
            return SizedBox(
              width: 220,
              child: Consumer(
                builder: (context, ref, child) {
                  final shaderPreference = ref.watch(shaderPreferenceProvider);
                  final shaderStrength = ref.watch(shaderStrengthProvider);
                  return DropdownMenu(
                    children: [
                      MenuButton(
                        child: const Text('Invert PDF Colors'),
                        trailing: Switch(
                          value: shaderPreference,
                          onChanged: (value) {
                            ref.read(shaderPreferenceProvider.notifier).state =
                                value;
                          },
                        ),
                      ),
                      MenuLabel(
                        child: Text('Inversion Strength:').small.normal,
                        trailing: Text(
                          shaderStrength.toStringAsFixed(2),
                        ).small.semiBold,
                      ),
                      MenuButton(
                        child: Slider(
                          min: 0.0,
                          max: 1.0,
                          value: SliderValue.single(shaderStrength),
                          onChanged: shaderPreference
                              ? (value) {
                                  ref
                                          .read(shaderStrengthProvider.notifier)
                                          .state =
                                      value.value;
                                }
                              : null,
                        ),
                      ),
                    ],
                  );
                },
              ),
            );
          },
        );
      },
      child: IconButton(
        icon: Icon(switch (currentTheme) {
          ThemeMode.light => Icons.wb_sunny_outlined,
          ThemeMode.dark => Icons.nightlight_outlined,
          ThemeMode.system => Icons.brightness_auto_outlined,
        }),
        onPressed: () {
          final nextTheme = switch (currentTheme) {
            ThemeMode.light => ThemeMode.dark,
            ThemeMode.dark => ThemeMode.system,
            ThemeMode.system => ThemeMode.light,
          };
          ref.read(themeModeProvider.notifier).state = nextTheme;
        },
        variance: ButtonStyle.ghostIcon(),
      ),
    );
  }
}
