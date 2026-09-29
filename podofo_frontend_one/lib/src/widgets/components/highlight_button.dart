import 'package:flutter/material.dart' as m;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' hide colorToHex;

import '../../providers/document_provider.dart';
import '../../providers/user_state_provider.dart';
import '../../services/document_actions.dart';
import '../../utils/color_utils.dart';

class HighlightButton extends ConsumerWidget {
  const HighlightButton({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(userStateNotifierProvider);
    final document = ref.watch(currentDocumentProvider);
    final color = colorFromHex(state.highlightColor ?? '#66ffeb3b');
    final allowed =
        document != null &&
        document.pdfDocument.permissions?.allowsModifyAnnotations != false;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        m.Tooltip(
          message: 'Highlight selected text',
          child: IconButton(
            icon: Icon(m.Icons.border_color, color: color.withAlpha(255)),
            onPressed: allowed ? () => DocumentActions.highlight(ref) : null,
            variance: ButtonStyle.ghostIcon(),
          ),
        ),
        m.PopupMenuButton<int>(
          tooltip: 'Highlight color',
          icon: const Icon(m.Icons.arrow_drop_down, size: 16),
          onSelected: (index) async {
            if (index >= 0) {
              ref
                  .read(userStateNotifierProvider.notifier)
                  .setHighlightActiveColorIndex(index);
              return;
            }
            var selected = ColorDerivative.fromColor(color);
            final chosen = await m.showDialog<Color>(
              context: context,
              builder: (context) => StatefulBuilder(
                builder: (context, setState) => m.AlertDialog(
                  title: const Text('Highlight color'),
                  content: SizedBox(
                    width: 240,
                    child: ColorInput(
                      value: selected,
                      promptMode: PromptMode.popover,
                      onChanged: (value) => setState(() => selected = value),
                    ),
                  ),
                  actions: [
                    m.TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Cancel'),
                    ),
                    m.FilledButton(
                      onPressed: () =>
                          Navigator.pop(context, selected.toColor()),
                      child: const Text('Apply'),
                    ),
                  ],
                ),
              ),
            );
            if (chosen != null && context.mounted) {
              ref
                  .read(userStateNotifierProvider.notifier)
                  .setHighlightColor(colorToHex(chosen));
            }
          },
          itemBuilder: (context) => [
            for (final entry in state.highlightColorPalette.asMap().entries)
              m.PopupMenuItem(
                value: entry.key,
                child: Row(
                  children: [
                    Icon(
                      m.Icons.circle,
                      color: colorFromHex(entry.value).withAlpha(255),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Color ${entry.key + 1}${entry.value == state.highlightColor ? ' (selected)' : ''}',
                    ),
                  ],
                ),
              ),
            const m.PopupMenuItem(value: -1, child: Text('Custom color…')),
          ],
        ),
      ],
    );
  }
}
