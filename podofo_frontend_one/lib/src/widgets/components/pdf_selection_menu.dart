import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import '../../providers/document_provider.dart';
import '../../services/document_actions.dart';
import 'highlight_palette.dart';

/// The original compact selection menu, backed by pdfrx's current delegate.
class PdfSelectionMenu extends ConsumerWidget {
  const PdfSelectionMenu({
    super.key,
    required this.params,
    required this.onHighlight,
  });

  final PdfViewerContextMenuBuilderParams params;
  final ValueChanged<String> onHighlight;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final document = ref.watch(currentDocumentProvider);
    final selection = params.textSelectionDelegate;
    final copy = selection.hasSelectedText && selection.isCopyAllowed;
    final highlight =
        selection.hasSelectedText &&
        document != null &&
        document.pdfDocument.permissions?.allowsModifyAnnotations != false;
    final selectAll =
        params.isTextSelectionEnabled && !selection.isSelectingAllText;
    if (!copy && !highlight && !selectAll) return const SizedBox.shrink();

    SingleActivator shortcut(LogicalKeyboardKey key) => SingleActivator(
      key,
      control: !Platform.isMacOS,
      meta: Platform.isMacOS,
    );

    Future<void> run(Future<void> Function() action) async {
      params.dismissContextMenu();
      try {
        await action();
      } catch (error) {
        if (context.mounted) DocumentActions.error(ref, error);
      }
    }

    return TapRegion(
      onTapOutside: (_) => params.dismissContextMenu(),
      child: SizedBox(
        width: 192,
        child: MenuGroup(
          direction: Axis.vertical,
          builder: (context, children) => MenuPopup(children: children),
          children: [
            if (copy)
              MenuButton(
                onPressed: (_) => run(() async {
                  await selection.copyTextSelection();
                }),
                trailing: MenuShortcut(
                  activator: shortcut(LogicalKeyboardKey.keyC),
                ),
                child: const Text('Copy'),
              ),
            if (selectAll)
              MenuButton(
                onPressed: (_) => run(selection.selectAllText),
                trailing: MenuShortcut(
                  activator: shortcut(LogicalKeyboardKey.keyA),
                ),
                child: const Text('Select all'),
              ),
            if (highlight) ...[
              if (copy || selectAll) const MenuDivider(),
              const MenuLabel(child: Text('Highlight')),
              MenuLabel(
                child: HighlightPalette(
                  onSelected: (color) {
                    params.dismissContextMenu();
                    onHighlight(color);
                  },
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
