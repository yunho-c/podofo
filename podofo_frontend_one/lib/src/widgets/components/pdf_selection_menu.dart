import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' hide colorToHex;

import '../../providers/document_provider.dart';
import '../../data/document_data.dart';
import '../../editing/annotation_edit.dart';
import '../../utils/color_utils.dart';
import '../../services/document_actions.dart';
import '../../services/context_menu_trace.dart';
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

  AnnotationRecord? resolve() {
    if (document.session.revision != revision) {
      throw StateError('Annotations changed. Open the menu again.');
    }
    return document.session.annotationAt(pageNumber, point.x, point.y);
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
    this.traceClick,
    this.onDismiss,
  });

  final PdfViewerContextMenuBuilderParams params;
  final ValueChanged<String> onHighlight;
  final VoidCallback onUnderline;
  final bool twoPageView;
  final ValueChanged<bool> onTwoPageViewChanged;
  final AnnotationMenuRequest? annotationRequest;
  final ContextMenuTraceClick? traceClick;
  final VoidCallback? onDismiss;

  @override
  ConsumerState<PdfSelectionMenu> createState() => _PdfSelectionMenuState();
}

class _PdfSelectionMenuState extends ConsumerState<PdfSelectionMenu> {
  AnnotationRecord? _target;
  bool _pending = false, _failed = false, _dismissed = false;
  bool _tracedFrame = false;
  final _menuFocus = FocusNode(debugLabel: 'PDF context menu');

  @override
  void initState() {
    super.initState();
    _resolveTarget();
    _focusMenu();
  }

  void _resolveTarget() {
    _target = null;
    _tracedFrame = false;
    _pending = false;
    _failed = false;
    _dismissed = false;
    final request = widget.annotationRequest;
    if (request == null) {
      widget.traceClick?.record('menu.target', {'result': 'no-page-request'});
      return;
    }
    if (request.document.session.annotationsReady) {
      try {
        _target = request.resolve();
        _traceTarget();
      } catch (_) {
        _failed = true;
        widget.traceClick?.record('menu.target-error');
      }
      return;
    }
    _pending = true;
    widget.traceClick?.record('menu.waiting-for-annotations');
    final click = widget.traceClick;
    request.document.session.prepareAnnotations().then(
      (_) => _finishTarget(request, click),
      onError: (Object _) => _finishTarget(request, click, failed: true),
    );
  }

  void _finishTarget(
    AnnotationMenuRequest request,
    ContextMenuTraceClick? click, {
    bool failed = false,
  }) {
    if (!mounted ||
        _dismissed ||
        !identical(widget.annotationRequest, request)) {
      click?.record('menu.late-result-ignored', {
        'mounted': mounted,
        'dismissed': _dismissed,
        'sameRequest': identical(widget.annotationRequest, request),
      });
      return;
    }
    setState(() {
      _pending = false;
      _failed = failed;
      if (!failed) {
        try {
          _target = request.resolve();
        } catch (_) {
          _failed = true;
        }
      }
    });
    _traceTarget();
    _focusMenu();
  }

  void _traceTarget() => widget.traceClick?.record('menu.target', {
    'result': _failed
        ? 'error'
        : (_target == null ? 'none' : _target!.kind.name),
    'editable': _target?.canEdit,
    'revision': widget.annotationRequest?.revision,
  });

  void _focusMenu() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_dismissed) _menuFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    widget.traceClick?.record('menu.disposed');
    _menuFocus.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant PdfSelectionMenu oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.annotationRequest != widget.annotationRequest) {
      _resolveTarget();
    }
    if (oldWidget.annotationRequest != widget.annotationRequest ||
        oldWidget.params.anchorA != widget.params.anchorA) {
      _focusMenu();
    }
  }

  void _dismiss(String reason) {
    widget.traceClick?.record('menu.dismissed', {'reason': reason});
    _dismissed = true;
    widget.onDismiss?.call();
    widget.params.dismissContextMenu();
  }

  @override
  Widget build(BuildContext context) {
    // While the first scan finishes, keep dismissal active but paint no popup.
    // Once loaded, both hit and no-hit menus render in their final form first.
    if (_pending) {
      return TapRegion(
        onTapOutside: (_) => _dismiss('outside-pointer'),
        child: Focus(
          focusNode: _menuFocus,
          onKeyEvent: (_, event) {
            if (event is KeyDownEvent &&
                event.logicalKey == LogicalKeyboardKey.escape) {
              _dismiss('escape-while-loading');
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: const SizedBox.shrink(),
        ),
      );
    }
    return _menu(context);
  }

  Widget _menu(BuildContext context) {
    final params = widget.params;
    final request = widget.annotationRequest;
    final document = ref.watch(currentDocumentProvider);
    final existing = request == null ? null : _target;
    final stale =
        request != null &&
        (document?.session != request.document.session ||
            request.document.session.lease.isClosed ||
            request.document.session.revision != request.revision);
    widget.traceClick?.record('menu.build', {
      'failed': _failed,
      'stale': stale,
      'target': existing?.kind.name,
      'selection': params.textSelectionDelegate.hasSelectedText,
      'part': params.contextMenuFor.name,
    });
    final canEdit =
        !stale &&
        !_failed &&
        existing?.canEdit == true &&
        document?.pdfDocument.permissions?.allowsModifyAnnotations != false;
    final selection = params.textSelectionDelegate;
    final copy = selection.hasSelectedText && selection.isCopyAllowed;
    final canMarkSelection =
        !_failed &&
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
      widget.traceClick?.record('menu.suppressed', {'reason': 'no-actions'});
      return const SizedBox.shrink();
    }

    if (!_tracedFrame && widget.traceClick != null) {
      _tracedFrame = true;
      final click = widget.traceClick;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _dismissed || !identical(widget.traceClick, click)) {
          return;
        }
        final box = context.findRenderObject();
        if (box is RenderBox && box.hasSize) {
          click?.record('menu.frame', {
            'width': box.size.width,
            'height': box.size.height,
          });
        }
      });
    }

    SingleActivator shortcut(LogicalKeyboardKey key) => SingleActivator(
      key,
      control: !Platform.isMacOS,
      meta: Platform.isMacOS,
    );

    Future<void> run(Future<void> Function() action) async {
      _dismiss('action');
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
      } else if (existing.kind == AnnotationKind.underline) {
        await notifier.highlightUnderline(
          request.document,
          existing.id,
          colorFromHex(color).toARGB32(),
          request.revision,
        );
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
      onTapOutside: (_) => _dismiss('outside-pointer'),
      child: SizedBox(
        width: 192,
        child: MenuGroup(
          focusNode: _menuFocus,
          onDismissed: () => _dismiss('menu-group'),
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
                    _dismiss('action');
                    widget.onHighlight(color);
                  },
                ),
              ),
            ],
            if (request != null && (_failed || stale))
              const MenuLabel(
                child: Text('Annotation unavailable. Reopen menu.'),
              ),
            if (existing != null && !stale && !_failed) ...[
              const MenuDivider(),
              MenuLabel(
                child: Text(
                  'Highlight',
                  style: const TextStyle(fontWeight: FontWeight.normal),
                ),
              ),
              if (canEdit)
                MenuLabel(
                  child: HighlightPalette(
                    selectedColor: existing.canRecolor
                        ? colorToHex(Color(existing.argb!))
                        : null,
                    updateDefault: false,
                    onSelected: (color) => edit(color: color),
                  ),
                ),
              if (!canEdit)
                MenuLabel(
                  child: Text('This ${existing.kind.name} is read-only'),
                ),
              if (canEdit)
                MenuButton(
                  onPressed: (_) => edit(),
                  child: Text('Remove ${existing.kind.name}'),
                ),
            ],
            if (underline)
              MenuButton(
                onPressed: (_) {
                  _dismiss('action');
                  widget.onUnderline();
                },
                child: const Text('Underline'),
              ),
            if (showView) ...[
              if (copy || highlight || selectAll) const MenuDivider(),
              ...pdfPageLayoutMenuItems(
                twoPageView: widget.twoPageView,
                onChanged: (enabled) {
                  _dismiss('action');
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
