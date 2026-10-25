import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' hide colorToHex;

import '../../providers/document_provider.dart';
import '../../data/document_data.dart';
import '../../editing/annotation_edit.dart';
import '../../editing/annotation_hit_test.dart';
import '../../utils/color_utils.dart';
import '../../services/document_actions.dart';
import '../../services/narration_actions.dart';
import '../../providers/narration_provider.dart';
import 'highlight_palette.dart';

List<MenuItem> pdfPageLayoutMenuItems({
  required bool twoPageView,
  required ValueChanged<bool> onChanged,
}) => [
  const MenuLabel(child: Text('View')),
  MenuButton(
    onPressed: (_) => onChanged(false),
    trailing: !twoPageView ? const Icon(RadixIcons.check).iconSmall() : null,
    child: Semantics(selected: !twoPageView, child: const Text('Single page')),
  ),
  MenuButton(
    onPressed: (_) => onChanged(true),
    trailing: twoPageView ? const Icon(RadixIcons.check).iconSmall() : null,
    child: Semantics(selected: twoPageView, child: const Text('Two pages')),
  ),
];

/// Captured on secondary pointer down, independently of any text selection.
class AnnotationMenuRequest {
  AnnotationMenuRequest(this.document, this.pageNumber, this.point)
    : revision = document.session.revision;

  final Document document;
  final int pageNumber, revision;
  final PdfPoint point;

  Future<AnnotationRecord?> resolve() async {
    final records = await document.session.annotations();
    if (document.session.revision != revision) {
      throw StateError('Annotations changed. Open the menu again.');
    }
    return textMarkupAt(records, pageNumber, point.x, point.y);
  }
}

/// Reader context menu, including existing text markup and selection actions.
class PdfSelectionMenu extends ConsumerStatefulWidget {
  const PdfSelectionMenu({
    super.key,
    required this.params,
    required this.onHighlight,
    required this.onUnderline,
    required this.twoPageView,
    required this.onTwoPageViewChanged,
    this.annotationRequest,
    this.onDismiss,
  });

  final PdfViewerContextMenuBuilderParams params;
  final ValueChanged<String> onHighlight;
  final VoidCallback onUnderline;
  final bool twoPageView;
  final ValueChanged<bool> onTwoPageViewChanged;
  final AnnotationMenuRequest? annotationRequest;
  final VoidCallback? onDismiss;

  @override
  ConsumerState<PdfSelectionMenu> createState() => _PdfSelectionMenuState();
}

class _PdfSelectionMenuState extends ConsumerState<PdfSelectionMenu> {
  Future<AnnotationRecord?>? _target;
  final _menuFocus = FocusNode(debugLabel: 'PDF context menu');

  @override
  void initState() {
    super.initState();
    _target = widget.annotationRequest?.resolve();
    _focusMenu();
  }

  void _focusMenu() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _menuFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _menuFocus.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant PdfSelectionMenu oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.annotationRequest != widget.annotationRequest) {
      _target = widget.annotationRequest?.resolve();
    }
    if (oldWidget.annotationRequest != widget.annotationRequest ||
        oldWidget.params.anchorA != widget.params.anchorA) {
      _focusMenu();
    }
  }

  void _dismiss() {
    widget.onDismiss?.call();
    widget.params.dismissContextMenu();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<AnnotationRecord?>(
    future: _target,
    builder: (context, snapshot) => _menu(context, snapshot),
  );

  Widget _menu(
    BuildContext context,
    AsyncSnapshot<AnnotationRecord?> snapshot,
  ) {
    final params = widget.params;
    final request = widget.annotationRequest;
    final document = ref.watch(currentDocumentProvider);
    final existing = request == null ? null : snapshot.data;
    final pending =
        request != null && snapshot.connectionState != ConnectionState.done;
    final stale =
        request != null &&
        (document?.session != request.document.session ||
            request.document.session.lease.isClosed ||
            request.document.session.revision != request.revision);
    final canEdit =
        !stale &&
        !pending &&
        !snapshot.hasError &&
        existing?.canEdit == true &&
        document?.pdfDocument.permissions?.allowsModifyAnnotations != false;
    final selection = params.textSelectionDelegate;
    final copy = selection.hasSelectedText && selection.isCopyAllowed;
    final canMarkSelection =
        !pending &&
        !snapshot.hasError &&
        !stale &&
        selection.hasSelectedText &&
        document != null &&
        document.pdfDocument.permissions?.allowsModifyAnnotations != false;
    final highlight = existing == null && canMarkSelection;
    final underline =
        canMarkSelection && existing?.kind != AnnotationKind.underline;
    final selectAll =
        params.isTextSelectionEnabled && !selection.isSelectingAllText;
    final showView = params.contextMenuFor == PdfViewerPart.background;
    if (!copy &&
        !highlight &&
        !underline &&
        !selectAll &&
        !showView &&
        request == null) {
      return const SizedBox.shrink();
    }

    SingleActivator shortcut(LogicalKeyboardKey key) => SingleActivator(
      key,
      control: !Platform.isMacOS,
      meta: Platform.isMacOS,
    );

    Future<void> run(Future<void> Function() action) async {
      _dismiss();
      try {
        await action();
      } catch (error) {
        if (context.mounted) DocumentActions.error(ref, error);
      }
    }

    Future<void> edit({String? color}) => run(() async {
      if (request == null ||
          existing == null ||
          ref.read(currentDocumentProvider)?.session !=
              request.document.session ||
          request.document.session.lease.isClosed ||
          request.document.session.revision != request.revision) {
        throw StateError('Annotations changed. Open the menu again.');
      }
      final notifier = ref.read(loadedDocumentsProvider.notifier);
      if (color == null) {
        await notifier.removeAnnotations(request.document, {
          existing.id,
        }, request.revision);
      } else {
        await notifier.recolorHighlights(
          request.document,
          {existing.id},
          colorFromHex(color).toARGB32(),
          request.revision,
        );
      }
    });

    return TapRegion(
      onTapOutside: (_) => _dismiss(),
      child: SizedBox(
        width: 192,
        child: MenuGroup(
          focusNode: _menuFocus,
          onDismissed: _dismiss,
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
            if (copy && ref.watch(narrationControllerProvider).available)
              MenuButton(
                onPressed: (_) =>
                    run(() => NarrationActions.readSelection(ref)),
                child: const Text('Read selection'),
              ),
            if (selection.isCopyAllowed &&
                ref.watch(narrationControllerProvider).available)
              MenuButton(
                onPressed: (_) => run(() => NarrationActions.readFromHere(ref)),
                child: const Text('Read from here'),
              ),
            if (highlight) ...[
              if (copy || selectAll) const MenuDivider(),
              const MenuLabel(
                child: Text(
                  'Highlight',
                  style: TextStyle(fontWeight: FontWeight.normal),
                ),
              ),
              MenuLabel(
                child: HighlightPalette(
                  onSelected: (color) {
                    _dismiss();
                    widget.onHighlight(color);
                  },
                ),
              ),
            ],
            if (request != null && (pending || snapshot.hasError || stale))
              MenuLabel(
                child: Text(
                  pending
                      ? 'Loading annotation…'
                      : 'Annotation unavailable. Reopen menu.',
                ),
              ),
            if (existing != null &&
                !stale &&
                !pending &&
                !snapshot.hasError) ...[
              const MenuDivider(),
              MenuLabel(
                child: Text(
                  existing.kind.label,
                  style: const TextStyle(fontWeight: FontWeight.normal),
                ),
              ),
              if (canEdit && existing.canRecolor)
                MenuLabel(
                  child: HighlightPalette(
                    selectedColor: colorToHex(Color(existing.argb!)),
                    updateDefault: false,
                    onSelected: (color) => edit(color: color),
                  ),
                ),
              if (!canEdit)
                MenuLabel(
                  child: Text('This ${existing.kind.name} is read-only'),
                ),
              MenuButton(
                onPressed: canEdit ? (_) => edit() : null,
                child: Text('Remove ${existing.kind.name}'),
              ),
            ],
            if (underline)
              MenuButton(
                onPressed: (_) {
                  _dismiss();
                  widget.onUnderline();
                },
                child: const Text('Underline'),
              ),
            if (showView) ...[
              if (copy || highlight || selectAll) const MenuDivider(),
              ...pdfPageLayoutMenuItems(
                twoPageView: widget.twoPageView,
                onChanged: (enabled) {
                  _dismiss();
                  widget.onTwoPageViewChanged(enabled);
                },
              ),
            ],
          ],
        ),
      ),
    );
  }
}
