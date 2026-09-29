import 'package:flutter/material.dart' as m;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' hide colorToHex;

import '../../providers/document_provider.dart';
import '../../providers/user_state_provider.dart';
import '../../services/document_actions.dart';
import '../../utils/color_utils.dart';
import 'highlight_palette.dart';

class HighlightButton extends ConsumerWidget {
  const HighlightButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(userStateNotifierProvider);
    final document = ref.watch(currentDocumentProvider);
    final theme = Theme.of(context);
    final color = colorFromHex(state.highlightColor ?? '#66ffeb3b');
    final allowed =
        document != null &&
        document.pdfDocument.permissions?.allowsModifyAnnotations != false;

    void showPalette(Offset position) {
      showDropdown(
        context: context,
        position: position,
        follow: false,
        builder: (_) => const SizedBox(
          width: 216,
          child: DropdownMenu(
            children: [
              MenuLabel(child: Text('Colors')),
              MenuLabel(child: HighlightPalette(showCustom: true)),
            ],
          ),
        ),
      );
    }

    return GestureDetector(
      onSecondaryTapUp: (details) => showPalette(details.globalPosition),
      onLongPressStart: (details) => showPalette(details.globalPosition),
      child: m.Tooltip(
        message: 'Highlighter',
        child: Semantics(
          toggled: state.highlightModeEnabled,
          child: IconButton(
            key: const ValueKey('highlight-mode'),
            icon: FaIcon(
              FontAwesomeIcons.highlighter,
              color: state.highlightModeEnabled
                  ? color.withAlpha(255)
                  : theme.colorScheme.mutedForeground.withAlpha(200),
            ),
            variance: ButtonStyle.ghostIcon(),
            onPressed: !allowed
                ? null
                : () {
                    final enabled = !state.highlightModeEnabled;
                    ref
                        .read(userStateNotifierProvider.notifier)
                        .setHighlightModeEnabled(enabled);
                    final controller = ref.read(pdfViewerControllerProvider);
                    if (enabled &&
                        controller.isReady &&
                        controller.textSelectionDelegate.hasSelectedText) {
                      DocumentActions.highlight(ref);
                    }
                  },
          ),
        ),
      ),
    );
  }
}
