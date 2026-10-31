import 'package:flutter/material.dart' as m;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' hide colorToHex;

import '../../providers/user_state_provider.dart';
import '../../utils/color_utils.dart';

/// Shared by creation and editing. Editing supplies its own selected color and
/// leaves the default creation color unchanged.
class HighlightPalette extends ConsumerWidget {
  const HighlightPalette({
    super.key,
    this.showCustom = false,
    this.onSelected,
    this.selectedColor,
    this.updateDefault = true,
  });

  final bool showCustom;
  final ValueChanged<String>? onSelected;
  final String? selectedColor;
  final bool updateDefault;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(userStateNotifierProvider);
    final theme = Theme.of(context);
    final activeColor = colorFromHex(
      selectedColor ?? state.highlightColor ?? '#66ffeb3b',
    );
    bool selected(String color) => colorFromHex(color) == activeColor;
    return Wrap(
      spacing: 2,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (!showCustom &&
            selectedColor != null &&
            !state.highlightColorPalette.any(selected))
          m.Tooltip(
            message: 'Current highlight color',
            child: Semantics(
              label: 'Current highlight color',
              selected: true,
              child: SizedBox(
                width: 24,
                height: 24,
                child: Center(
                  child: Container(
                    width: 16,
                    height: 16,
                    decoration: BoxDecoration(
                      color: activeColor.withAlpha(255),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: theme.colorScheme.muted,
                        width: 4,
                        strokeAlign: BorderSide.strokeAlignOutside,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        for (final entry in state.highlightColorPalette.asMap().entries)
          Semantics(
            label: 'Highlight color ${entry.key + 1}',
            selected: selected(entry.value),
            child: m.IconButton(
              key: ValueKey('highlight-color-${entry.key}'),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 24, height: 24),
              iconSize: 16,
              onPressed: () {
                if (updateDefault) {
                  ref
                      .read(userStateNotifierProvider.notifier)
                      .setHighlightActiveColorIndex(entry.key);
                }
                onSelected?.call(entry.value);
              },
              icon: Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  // Swatches show the hue; alpha is reserved for the PDF mark.
                  color: colorFromHex(entry.value).withAlpha(255),
                  shape: BoxShape.circle,
                  border: selected(entry.value)
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
                value: ColorDerivative.fromColor(activeColor),
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
                        handler.value ?? ColorDerivative.fromColor(activeColor),
                    initialMode: ColorPickerMode.hex,
                    showAlpha: true,
                    enableEyeDropper: false,
                    onChanged: (value) => handler.value = value,
                  ),
                ),
                onChanged: (value) {
                  if (value == null) return;
                  if (updateDefault) {
                    ref
                        .read(userStateNotifierProvider.notifier)
                        .setHighlightColor(colorToHex(value.toColor()));
                  }
                  onSelected?.call(colorToHex(value.toColor()));
                  ColorHistoryStorage.of(context).addHistory(value.toColor());
                },
              ),
            ),
          ),
      ],
    );
  }
}
