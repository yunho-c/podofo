// FORKED VERSION from shadcn_flutter/lib/src/components/menu/context_menu.dart

// Here is a summary of the main differences between your custom context menu and the original shadcn_flutter version:

//    1. Generalization: The original context menu was specifically built for EditableTextState. Your custom version is adapted for the more general
//       SelectableRegionState. This is reflected in the class names changing from ...EditableTextContextMenu to ...SelectableRegionContextMenu.

//    2. Simplified Button Handling:
//        * The original version manually checked for each ContextMenuButtonType (e.g., cut, copy, paste) and created a corresponding widget.
//        * Your version is more generic. It accepts a List<ContextMenuButtonItem> and iterates through it to build the menu, removing the need to handle each
//          button type individually.

//    3. Removal of Undo/Redo: The logic for UndoHistoryController has been completely removed. This makes sense because SelectableRegion is for read-only
//       content and doesn't have an undo history, unlike an EditableText field.

//    4. Parameter Changes: The constructor now takes a SelectableRegionState and a List<ContextMenuButtonItem> instead of an EditableTextState and an optional
//       UndoHistoryController.

//   In short, your custom_context_menu.dart is a simplified and more generic version of the shadcn_flutter original, specifically tailored to work with a
//   SelectableRegion by removing features exclusive to editable text fields.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:podofo_one/src/providers/user_state_provider.dart';
import 'package:podofo_one/src/utils/color_utils.dart';
// import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

class DesktopSelectableRegionContextMenu extends ConsumerWidget {
  final BuildContext anchorContext;
  final SelectableRegionState selectableRegionState;
  final List<ContextMenuButtonItem> buttonItems;

  const DesktopSelectableRegionContextMenu({
    super.key,
    required this.anchorContext,
    required this.selectableRegionState,
    required this.buttonItems,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scaling = theme.scaling;
    final localizations = ShadcnLocalizations.of(context);
    final userState = ref.watch(userStateNotifierProvider);

    final Map<ContextMenuButtonType, (ShortcutActivator, String)> shortcuts = {
      ContextMenuButtonType.copy: (
        const SingleActivator(LogicalKeyboardKey.keyC, control: true),
        localizations.menuCopy,
      ),
      ContextMenuButtonType.selectAll: (
        const SingleActivator(LogicalKeyboardKey.keyA, control: true),
        localizations.menuSelectAll,
      ),
      ContextMenuButtonType.cut: (
        const SingleActivator(LogicalKeyboardKey.keyX, control: true),
        localizations.menuCut,
      ),
      ContextMenuButtonType.paste: (
        const SingleActivator(LogicalKeyboardKey.keyV, control: true),
        localizations.menuPaste,
      ),
    };

    final List<MenuItem> menuItems = [];
    for (final ContextMenuButtonItem buttonItem in buttonItems) {
      if (buttonItem.type == ContextMenuButtonType.custom &&
          buttonItem.label == 'Highlight') {
        menuItems.add(
          MenuButton(
            onPressed: (context) {},
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Highlight'),
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.start,
                  children: [
                    Row(
                      children: userState.highlightColorPalette.map((colorHex) {
                        final color = colorFromHex(colorHex);
                        return GestureDetector(
                          onTap: () {
                            ref
                                .read(userStateNotifierProvider.notifier)
                                .setHighlightColor(colorHex);
                            selectableRegionState.hideToolbar();
                          },
                          child: Container(
                            width: 16,
                            height: 16,
                            margin: const EdgeInsets.symmetric(horizontal: 4),
                            decoration: BoxDecoration(
                              color: color,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: theme.colorScheme.muted,
                                width: userState.highlightColor == colorHex
                                    ? 5
                                    : 0,
                                strokeAlign: BorderSide.strokeAlignOutside,
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      } else {
        final shortcutData = shortcuts[buttonItem.type];
        menuItems.add(
          MenuButton(
            onPressed: (context) {
              buttonItem.onPressed?.call();
            },
            trailing: shortcutData != null
                ? MenuShortcut(activator: shortcutData.$1)
                : null,
            child: Text(buttonItem.label ?? shortcutData?.$2 ?? 'Action'),
          ),
        );
      }
    }

    return TapRegion(
      child: ShadcnUI(
        child: ContextMenuPopup(
          anchorSize: Size.zero,
          anchorContext: anchorContext,
          position:
              selectableRegionState.contextMenuAnchors.primaryAnchor +
              const Offset(8, -8) * scaling,
          children: menuItems,
        ),
      ),
    );
  }
}

class MobileSelectableRegionContextMenu extends ConsumerWidget {
  final BuildContext anchorContext;
  final SelectableRegionState selectableRegionState;
  final List<ContextMenuButtonItem> buttonItems;

  const MobileSelectableRegionContextMenu({
    super.key,
    required this.anchorContext,
    required this.selectableRegionState,
    required this.buttonItems,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scaling = theme.scaling;
    final userState = ref.watch(userStateNotifierProvider);

    final List<MenuItem> menuItems = [];
    for (final ContextMenuButtonItem buttonItem in buttonItems) {
      if (buttonItem.type == ContextMenuButtonType.custom &&
          buttonItem.label == 'Highlight') {
        menuItems.add(
          MenuButton(
            onPressed: (context) {},
            child: Row(
              mainAxisAlignment: MainAxisAlignment.start,
              children: [
                const Text('Highlight'),
                const SizedBox(width: 8),
                Row(
                  children: userState.highlightColorPalette.map((colorHex) {
                    final color = colorFromHex(colorHex);
                    return GestureDetector(
                      onTap: () {
                        ref
                            .read(userStateNotifierProvider.notifier)
                            .setHighlightColor(colorHex);
                        selectableRegionState.hideToolbar();
                      },
                      child: Container(
                        width: 16,
                        height: 16,
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: userState.highlightColor == colorHex
                                ? theme.colorScheme.primary
                                : theme.colorScheme.border,
                            width: 2,
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ],
            ),
          ),
        );
      } else {
        menuItems.add(
          MenuButton(
            onPressed: (context) {
              buttonItem.onPressed?.call();
            },
            child: Text(buttonItem.label ?? 'Action'),
          ),
        );
      }
    }

    var primaryAnchor =
        (selectableRegionState.contextMenuAnchors.secondaryAnchor ??
            selectableRegionState.contextMenuAnchors.primaryAnchor) +
        const Offset(-8, 8) * scaling;

    return TapRegion(
      child: ShadcnUI(
        child: ContextMenuPopup(
          anchorSize: Size.zero,
          anchorContext: anchorContext,
          position: primaryAnchor,
          direction: Axis.horizontal,
          children: menuItems.joinSeparator(const MenuDivider()),
        ),
      ),
    );
  }
}

Widget buildSelectableRegionContextMenu(
  BuildContext innerContext,
  SelectableRegionState selectableRegionState,
  List<ContextMenuButtonItem> buttonItems,
) {
  TargetPlatform platform = Theme.of(innerContext).platform;

  switch (platform) {
    case TargetPlatform.android:
    case TargetPlatform.iOS:
      return MobileSelectableRegionContextMenu(
        anchorContext: innerContext,
        selectableRegionState: selectableRegionState,
        buttonItems: buttonItems,
      );
    case TargetPlatform.macOS:
    case TargetPlatform.windows:
    case TargetPlatform.linux:
    case TargetPlatform.fuchsia:
      return DesktopSelectableRegionContextMenu(
        anchorContext: innerContext,
        selectableRegionState: selectableRegionState,
        buttonItems: buttonItems,
      );
  }
}

class ContextMenuPopup extends StatelessWidget {
  final BuildContext anchorContext;
  final Offset position;
  final List<MenuItem> children;
  final CapturedThemes? themes;
  final Axis direction;
  final ValueChanged<PopoverOverlayWidgetState>? onTickFollow;
  final Size? anchorSize;
  const ContextMenuPopup({
    super.key,
    required this.anchorContext,
    required this.position,
    required this.children,
    this.themes,
    this.direction = Axis.vertical,
    this.onTickFollow,
    this.anchorSize,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedValueBuilder.animation(
      value: 1.0,
      initialValue: 0.0,
      duration: const Duration(milliseconds: 100),
      builder: (context, animation) {
        final isSheetOverlay = SheetOverlayHandler.isSheetOverlay(context);
        return PopoverOverlayWidget(
          anchorContext: anchorContext,
          position: position,
          anchorSize: anchorSize,
          alignment: Alignment.topLeft,
          themes: themes,
          follow: onTickFollow != null,
          onTickFollow: onTickFollow,
          builder: (context) {
            final theme = Theme.of(context);
            return LimitedBox(
              maxWidth: 192 * theme.scaling,
              child: MenuGroup(
                direction: direction,
                itemPadding: isSheetOverlay
                    ? const EdgeInsets.symmetric(horizontal: 8) * theme.scaling
                    : EdgeInsets.zero,
                builder: (context, children) {
                  return MenuPopup(children: children);
                },
                children: children,
              ),
            );
          },
          animation: animation,
          anchorAlignment: Alignment.topRight,
        );
      },
    );
  }
}
