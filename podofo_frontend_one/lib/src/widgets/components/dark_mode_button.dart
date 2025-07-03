import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'package:podofo_one/src/providers/providers.dart';

class DarkModeButton extends ConsumerWidget {
  const DarkModeButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    final userPreferenceNotifier = ref.read(userPreferenceProvider.notifier);

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
                            userPreferenceNotifier.setShaderPreference(value);
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
                                  userPreferenceNotifier.setShaderStrength(
                                    value.value,
                                  );
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
        icon: Icon(switch (themeMode) {
          ThemeMode.light => Icons.wb_sunny_outlined,
          ThemeMode.dark => Icons.nightlight_outlined,
          ThemeMode.system => Icons.brightness_auto_outlined,
        }),
        onPressed: () {
          final nextTheme = switch (themeMode) {
            ThemeMode.light => ThemeMode.dark,
            ThemeMode.dark => ThemeMode.system,
            ThemeMode.system => ThemeMode.light,
          };
          userPreferenceNotifier.setThemeMode(nextTheme);
        },
        variance: ButtonStyle.ghostIcon(),
      ),
    );
  }
}
