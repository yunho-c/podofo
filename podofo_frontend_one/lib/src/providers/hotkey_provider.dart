import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../data/pane_data.dart';
import '../services/document_actions.dart';
import 'document_provider.dart';
import 'tab_provider.dart';
import 'ui_provider.dart';

/// Flutter shortcuts respect text-field focus and disappear with the app widget.
class AppShortcuts extends ConsumerWidget {
  const AppShortcuts({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isMac = defaultTargetPlatform == TargetPlatform.macOS;
    SingleActivator chord(
      LogicalKeyboardKey key, {
      bool shift = false,
      bool repeat = true,
    }) => SingleActivator(
      key,
      control: !isMac,
      meta: isMac,
      shift: shift,
      includeRepeats: repeat,
    );
    void history({required bool redo}) {
      // CallbackShortcuts may see the key before the app's default text
      // shortcuts. Resolve the focused field's own action explicitly, including
      // when its history is empty; never fall through to document undo.
      final focus = FocusManager.instance.primaryFocus?.context;
      if (focus?.widget is EditableText ||
          focus?.findAncestorStateOfType<EditableTextState>() != null) {
        Actions.maybeInvoke(
          focus!,
          redo
              ? const RedoTextIntent(SelectionChangedCause.keyboard)
              : const UndoTextIntent(SelectionChangedCause.keyboard),
        );
        return;
      }
      if (redo) {
        DocumentActions.redo(ref);
      } else {
        DocumentActions.undo(ref);
      }
    }

    void save({bool as = false}) {
      final document = ref.read(currentDocumentProvider);
      if (document != null) {
        DocumentActions.save(context, ref, document, saveAs: as);
      }
    }

    void next(int delta) {
      final count = ref.read(loadedDocumentsProvider).length;
      if (count > 0) {
        final index = ref.read(currentTabIndexProvider);
        ref.read(currentTabIndexProvider.notifier).state =
            (index + delta) % count;
      }
    }

    return CallbackShortcuts(
      bindings: {
        chord(LogicalKeyboardKey.keyZ, repeat: false): () =>
            history(redo: false),
        chord(LogicalKeyboardKey.keyZ, shift: true, repeat: false): () =>
            history(redo: true),
        if (!isMac)
          chord(LogicalKeyboardKey.keyY, repeat: false): () =>
              history(redo: true),
        chord(LogicalKeyboardKey.keyO): () =>
            ref.read(filePathProvider.notifier).pickFile(),
        chord(LogicalKeyboardKey.keyS): () => save(),
        chord(LogicalKeyboardKey.keyS, shift: true): () => save(as: true),
        chord(LogicalKeyboardKey.keyW): () {
          final document = ref.read(currentDocumentProvider);
          if (document != null) DocumentActions.close(context, ref, document);
        },
        chord(LogicalKeyboardKey.keyQ): () => windowManager.close(),
        chord(LogicalKeyboardKey.keyH, shift: true): () =>
            DocumentActions.highlight(ref),
        chord(LogicalKeyboardKey.keyF): () =>
            ref.read(leftPaneProvider.notifier).state = leftPaneData.items[3],
        chord(LogicalKeyboardKey.keyB): () =>
            ref.read(leftPaneProvider.notifier).state = leftPaneData.items[0],
        chord(LogicalKeyboardKey.keyP): () =>
            ref.read(commandPaletteProvider.notifier).update((v) => !v),
        const SingleActivator(LogicalKeyboardKey.tab, control: true): () =>
            next(1),
        const SingleActivator(
          LogicalKeyboardKey.tab,
          control: true,
          shift: true,
        ): () =>
            next(-1),
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            ref.read(commandPaletteProvider.notifier).state = false,
        for (var n = 1; n <= 9; n++)
          chord(
            [
              LogicalKeyboardKey.digit1,
              LogicalKeyboardKey.digit2,
              LogicalKeyboardKey.digit3,
              LogicalKeyboardKey.digit4,
              LogicalKeyboardKey.digit5,
              LogicalKeyboardKey.digit6,
              LogicalKeyboardKey.digit7,
              LogicalKeyboardKey.digit8,
              LogicalKeyboardKey.digit9,
            ][n - 1],
          ): () {
            if (n <= ref.read(loadedDocumentsProvider).length) {
              ref.read(currentTabIndexProvider.notifier).state = n - 1;
            }
          },
        chord(LogicalKeyboardKey.digit0): () {
          final count = ref.read(loadedDocumentsProvider).length;
          if (count > 0) {
            ref.read(currentTabIndexProvider.notifier).state = count - 1;
          }
        },
      },
      child: Focus(autofocus: true, child: child),
    );
  }
}
