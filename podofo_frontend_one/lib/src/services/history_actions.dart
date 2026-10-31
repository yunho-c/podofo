import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/document_data.dart';
import '../providers/document_provider.dart';
import 'document_actions.dart';

/// A history target captured before a popup menu takes focus. Text fields never
/// fall through to document history, including when their history is empty.
class HistoryActions {
  HistoryActions._(this.ref, this.document, this.focus, this.text);

  factory HistoryActions.resolve(WidgetRef ref) {
    final focus = FocusManager.instance.primaryFocus?.context;
    final text = focus?.findAncestorStateOfType<EditableTextState>();
    return HistoryActions._(
      ref,
      ref.read(currentDocumentProvider),
      focus,
      text,
    );
  }

  final WidgetRef ref;
  final Document? document;
  final BuildContext? focus;
  final EditableTextState? text;

  bool get _isText => text != null || focus?.widget is EditableText;
  // App-owned fields provide an explicit controller for exact availability.
  // For library-owned fields, respect Flutter's Action enablement. Their empty
  // text undo may be a no-op, but must never fall through to document undo.
  Listenable? get changes => text?.widget.undoController;
  bool _textEnabled({required bool redo}) {
    if (text?.widget.readOnly == true || focus?.mounted != true) return false;
    if (text?.widget.undoController case final controller?) {
      return redo ? controller.value.canRedo : controller.value.canUndo;
    }
    return redo
        ? (Actions.maybeFind<RedoTextIntent>(focus!)?.isEnabled(
                const RedoTextIntent(SelectionChangedCause.keyboard),
              ) ??
              false)
        : (Actions.maybeFind<UndoTextIntent>(focus!)?.isEnabled(
                const UndoTextIntent(SelectionChangedCause.keyboard),
              ) ??
              false);
  }

  bool get canUndo =>
      _isText ? _textEnabled(redo: false) : document?.session.canUndo ?? false;
  bool get canRedo =>
      _isText ? _textEnabled(redo: true) : document?.session.canRedo ?? false;
  String get undoLabel =>
      !_isText && canUndo ? 'Undo ${document!.session.undoLabel}' : 'Undo';
  String get redoLabel =>
      !_isText && canRedo ? 'Redo ${document!.session.redoLabel}' : 'Redo';

  void invoke({required bool redo}) {
    if (!ref.context.mounted) return;
    if (_isText) {
      // Use the captured field's own Actions even if a popup now owns focus.
      // A field removed while the menu is open must not redirect to the PDF.
      if (focus?.mounted != true || text?.mounted == false) return;
      Actions.maybeInvoke(
        focus!,
        redo
            ? const RedoTextIntent(SelectionChangedCause.keyboard)
            : const UndoTextIntent(SelectionChangedCause.keyboard),
      );
      return;
    }
    final current = ref.read(currentDocumentProvider);
    if (document == null ||
        current?.session != document!.session ||
        document!.session.lease.isClosed) {
      return;
    }
    if (redo) {
      DocumentActions.redo(ref);
    } else {
      DocumentActions.undo(ref);
    }
  }
}
