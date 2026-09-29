import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import '../../providers/user_state_provider.dart';
import '../../providers/document_provider.dart';
import '../../services/document_actions.dart';
import 'hotkey_editor.dart';

class MoreOptionsDropdown extends ConsumerWidget {
  const MoreOptionsDropdown({
    super.key,
    required this.ownerContext,
    required this.ownerRef,
  });
  final BuildContext ownerContext;
  final WidgetRef ownerRef;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(userStateNotifierProvider);
    final document = ref.watch(currentDocumentProvider);
    return DropdownMenu(
      children: [
        MenuButton(
          onPressed: document == null
              ? null
              : (_) => DocumentActions.save(ownerContext, ownerRef, document),
          enabled: document != null,
          child: const Text('Save'),
        ),
        MenuButton(
          onPressed: document == null
              ? null
              : (_) => DocumentActions.save(
                  ownerContext,
                  ownerRef,
                  document,
                  saveAs: true,
                ),
          enabled: document != null,
          child: const Text('Save As…'),
        ),
        MenuButton(
          enabled: document?.session.canUndo ?? false,
          onPressed: (_) async {
            try {
              await ownerRef
                  .read(loadedDocumentsProvider.notifier)
                  .undoHighlight(document!);
            } catch (e) {
              if (ownerContext.mounted) DocumentActions.error(ownerRef, e);
            }
          },
          child: const Text('Undo last highlight'),
        ),
        MenuButton(
          trailing: Switch(
            value: state.autoSaveEnabled,
            onChanged: (value) => ref
                .read(userStateNotifierProvider.notifier)
                .setAutoSaveEnabled(value),
          ),
          child: const Text('Auto-save new highlights'),
        ),
        const MenuDivider(),
        MenuButton(
          onPressed: (_) => HotkeyEditor.show(ownerContext),
          child: const Text('Keyboard shortcuts'),
        ),
        for (final label in [
          'Utilities',
          'Extensions',
          'Audio reader',
          'AI tools',
          'Study tools',
        ])
          MenuButton(enabled: false, child: Text('$label — not available yet')),
        const MenuDivider(),
        const MenuLabel(child: Text('PoDoFo 1.0.0')),
        const MenuLabel(
          child: Text(
            'Link previews show destinations without network requests.',
          ),
        ),
      ],
    );
  }
}
