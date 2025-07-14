import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' hide colorToHex;

import 'package:podofo_one/src/providers/user_state_provider.dart';
import 'package:podofo_one/src/utils/color_utils.dart';

class HighlightButton extends ConsumerWidget {
  const HighlightButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final userState = ref.watch(userStateNotifierProvider);
    final selectedColor = userState.highlightColor != null
        ? colorFromHex(userState.highlightColor!)
        : Colors.yellow;
    final highlightColors = userState.highlightColorPalette
        .map((hex) => colorFromHex(hex))
        .where((c) => c != null)
        .cast<Color>()
        .toList();

    Widget icon;
    if (userState.highlightModeEnabled) {
      final color = selectedColor;
      icon = ColorFiltered(
        colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
        child: FaIcon(
          FontAwesomeIcons.highlighter,
          color: Theme.of(context).colorScheme.foreground,
        ),
      );
    } else {
      icon = FaIcon(
        FontAwesomeIcons.highlighter,
        color: Theme.of(context).colorScheme.mutedForeground.withAlpha(200),
      );
    }

    return GestureDetector(
      onSecondaryTapUp: (details) {
        showDropdown(
          context: context,
          position: details.globalPosition,
          builder: (context) {
            return DropdownMenu(
              children: [
                MenuButton(
                  enabled: false,
                  child: const Text('Colors').xSmall.medium.muted,
                ),
                MenuButton(
                  enabled: false,
                  child: Text(
                    'Right-click to customize',
                    style: TextStyle(fontSize: 10),
                  ).muted,
                ),
                MenuButton(
                  enabled: false,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8.0),
                    child: Row(
                      children: [
                        ...highlightColors.asMap().entries.map((entry) {
                          final index = entry.key;
                          final color = entry.value;
                          return Padding(
                            padding: const EdgeInsets.only(right: 8.0),
                            child: _HighlightColorButton(
                              color: color,
                              isSelected:
                                  userState.highlightActiveColorIndex == index,
                              onPressed: () {
                                ref
                                    .read(userStateNotifierProvider.notifier)
                                    .setHighlightActiveColorIndex(index);
                              },
                            ),
                          );
                        }).toList(),
                        SizedBox(
                          width: 16,
                          height: 16,
                          child: ColorInput(
                            color: ColorDerivative.fromColor(
                              selectedColor ?? Colors.yellow,
                            ),
                            mode: PromptMode.popover,
                            onChanged: (value) {
                              ref
                                  .read(userStateNotifierProvider.notifier)
                                  .setHighlightColor(
                                    colorToHex(value.toColor()),
                                  );
                            },
                            storage: ColorHistoryStorage.of(context),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                MenuDivider(),
                MenuButton(
                  subMenu: [
                    MenuButton(
                      child: Text('Use H key to toggle on/off'),
                      trailing: Switch(value: false, onChanged: (value) {}),
                    ),
                    MenuButton(
                      child: Text('Use number keys to change colors'),
                      trailing: Switch(value: false, onChanged: (value) {}),
                    ),
                    MenuButton(
                      child: Text('Use number keys to highlight'),
                      trailing: Switch(value: false, onChanged: (value) {}),
                    ),
                    MenuButton(
                      child: Text('Show highlight options in context menu'),
                      trailing: Switch(value: false, onChanged: (value) {}),
                    ),
                  ],
                  child: Text('Settings'),
                ),
              ],
            );
          },
        );
      },
      child: IconButton(
        icon: icon,
        onPressed: () {
          ref
              .read(userStateNotifierProvider.notifier)
              .setHighlightModeEnabled(!userState.highlightModeEnabled);
        },
        variance: ButtonStyle.ghostIcon(),
      ),
    );
  }
}

class _HighlightColorButton extends StatelessWidget {
  final Color color;
  final bool isSelected;
  final VoidCallback onPressed;

  const _HighlightColorButton({
    required this.color,
    required this.isSelected,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        width: 16,
        height: 16,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: isSelected
              ? Border.all(
                  color: Theme.of(context).colorScheme.foreground,
                  width: 2,
                )
              : null,
        ),
      ),
    );
  }
}
