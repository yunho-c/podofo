import 'package:flutter/material.dart' as m;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' hide colorToHex;

import '../../providers/user_state_provider.dart';
import '../../utils/color_utils.dart';

/// Shared by the toolbar palette and the PDF's selection menu.
class HighlightPalette extends ConsumerWidget {
  const HighlightPalette({super.key, this.showCustom = false, this.onSelected});

  final bool showCustom;
  final ValueChanged<String>? onSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(userStateNotifierProvider);
    final theme = Theme.of(context);
    final selectedColor = colorFromHex(state.highlightColor ?? '#66ffeb3b');
    return Wrap(
      spacing: 2,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final entry in state.highlightColorPalette.asMap().entries)
          Semantics(
            label: 'Highlight color ${entry.key + 1}',
            selected: entry.value == state.highlightColor,
            child: m.IconButton(
              key: ValueKey('highlight-color-${entry.key}'),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 24, height: 24),
              iconSize: 16,
              onPressed: () {
                ref
                    .read(userStateNotifierProvider.notifier)
                    .setHighlightActiveColorIndex(entry.key);
                onSelected?.call(entry.value);
              },
              icon: Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  // Swatches show the hue; alpha is reserved for the PDF mark.
                  color: colorFromHex(entry.value).withAlpha(255),
                  shape: BoxShape.circle,
                  border: entry.value == state.highlightColor
                      ? Border.all(
                          color: theme.colorScheme.muted,
                          width: 4,
                          strokeAlign: BorderSide.strokeAlignOutside,
                        )
                      : null,
                ),
              ),
            ),
          ),
        if (showCustom)
          m.Tooltip(
            message: 'Custom color',
            child: SizedBox(
              width: 24,
              height: 24,
              child: ObjectFormField<ColorDerivative>(
                key: const ValueKey('highlight-custom-color'),
                placeholder: const SizedBox.shrink(),
                value: ColorDerivative.fromColor(selectedColor),
                mode: PromptMode.popover,
                density: ButtonDensity.iconDense,
                immediateValueChange: true,
                builder: (context, value) => Container(
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    color: value.toColor().withAlpha(255),
                    borderRadius: BorderRadius.circular(3),
                    border: Border.all(color: theme.colorScheme.border),
                  ),
                ),
                editorBuilder: (context, handler) => SizedBox(
                  width: 300,
                  child: ColorPicker(
                    value:
                        handler.value ??
                        ColorDerivative.fromColor(selectedColor),
                    initialMode: ColorPickerMode.hex,
                    showAlpha: true,
                    enableEyeDropper: false,
                    onChanged: (value) => handler.value = value,
                  ),
                ),
                onChanged: (value) {
                  if (value == null) return;
                  ref
                      .read(userStateNotifierProvider.notifier)
                      .setHighlightColor(colorToHex(value.toColor()));
                  ColorHistoryStorage.of(context).addHistory(value.toColor());
                },
              ),
            ),
          ),
      ],
    );
  }
}
