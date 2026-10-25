import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter/material.dart' as m;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:window_manager/window_manager.dart';

import '../../providers/document_provider.dart';
import '../../providers/ui_provider.dart';
import '../../services/document_actions.dart';
import '../../services/history_actions.dart';

class TitleBar extends ConsumerStatefulWidget {
  const TitleBar({super.key, required this.child});
  final Widget child;
  @override
  ConsumerState<TitleBar> createState() => _TitleBarState();
}

class _TitleBarState extends ConsumerState<TitleBar> {
  Listenable? _textHistory;
  bool _refreshScheduled = false;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_refresh);
  }

  void _refresh() {
    if (!mounted || _refreshScheduled) return;
    if (SchedulerBinding.instance.schedulerPhase !=
        SchedulerPhase.persistentCallbacks) {
      setState(() {});
      return;
    }
    _refreshScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshScheduled = false;
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_refresh);
    _textHistory?.removeListener(_refresh);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final document = ref.watch(currentDocumentProvider);
    final history = HistoryActions.resolve(ref);
    if (!identical(_textHistory, history.changes)) {
      _textHistory?.removeListener(_refresh);
      _textHistory = history.changes;
      _textHistory?.addListener(_refresh);
    }
    final isMacOS = defaultTargetPlatform == TargetPlatform.macOS;
    final content = Column(
      children: [
        SizedBox(
          height: 32,
          child: Row(
            children: [
              SizedBox(
                width: 80,
                // Reserve space for the native macOS window controls.
                child: isMacOS
                    ? null
                    : m.PopupMenuButton<String>(
                        tooltip: 'File menu',
                        child: const Center(child: Text('File')),
                        itemBuilder: (context) => [
                          const m.PopupMenuItem(
                            value: 'open',
                            child: Text('Open PDF…'),
                          ),
                          m.PopupMenuItem(
                            value: 'save',
                            enabled: document != null,
                            child: const Text('Save'),
                          ),
                          m.PopupMenuItem(
                            value: 'saveAs',
                            enabled: document != null,
                            child: const Text('Save As…'),
                          ),
                          m.PopupMenuItem(
                            value: 'close',
                            enabled: document != null,
                            child: const Text('Close tab'),
                          ),
                          const m.PopupMenuItem(
                            enabled: false,
                            child: Text('Print'),
                          ),
                          const m.PopupMenuItem(
                            enabled: false,
                            child: Text('Export'),
                          ),
                        ],
                        onSelected: (value) {
                          switch (value) {
                            case 'open':
                              ref.read(filePathProvider.notifier).pickFile();
                            case 'save':
                              DocumentActions.save(context, ref, document!);
                            case 'saveAs':
                              DocumentActions.save(
                                context,
                                ref,
                                document!,
                                saveAs: true,
                              );
                            case 'close':
                              DocumentActions.close(context, ref, document!);
                          }
                        },
                      ),
              ),
              if (!isMacOS)
                m.TextFieldTapRegion(
                  child: m.PopupMenuButton<VoidCallback>(
                    tooltip: 'Edit menu',
                    requestFocus: true,
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16),
                      child: Text('Edit'),
                    ),
                    itemBuilder: (_) {
                      final target = HistoryActions.resolve(ref);
                      return [
                        m.PopupMenuItem(
                          enabled: target.canUndo,
                          value: () => target.invoke(redo: false),
                          child: Text(target.undoLabel),
                        ),
                        m.PopupMenuItem(
                          enabled: target.canRedo,
                          value: () => target.invoke(redo: true),
                          child: Text(target.redoLabel),
                        ),
                      ];
                    },
                    onSelected: (action) => action(),
                  ),
                ),
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanStart: (_) => windowManager.startDragging(),
                  child: Center(
                    child: Semantics(
                      label: 'Recent files',
                      button: true,
                      child: GestureDetector(
                        onTap: () => ref
                            .read(commandPaletteProvider.notifier)
                            .update((value) => !value),
                        child: Container(
                          width: 200,
                          height: 15,
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.accent,
                            borderRadius: BorderRadius.circular(5),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (!isMacOS)
                SizedBox(
                  width: 138,
                  child: WindowCaption(
                    brightness: Theme.of(context).colorScheme.brightness,
                    backgroundColor: Colors.transparent,
                  ),
                ),
            ],
          ),
        ),
        Expanded(child: widget.child),
      ],
    );
    if (!isMacOS) return content;
    return PlatformMenuBar(
      menus: [
        // macOS reserves the first menu for the application menu.
        PlatformMenu(
          label: 'PoDoFo',
          menus: [
            const PlatformMenuItemGroup(
              members: [
                PlatformProvidedMenuItem(
                  type: PlatformProvidedMenuItemType.about,
                ),
              ],
            ),
            const PlatformMenuItemGroup(
              members: [
                PlatformProvidedMenuItem(
                  type: PlatformProvidedMenuItemType.servicesSubmenu,
                ),
              ],
            ),
            const PlatformMenuItemGroup(
              members: [
                PlatformProvidedMenuItem(
                  type: PlatformProvidedMenuItemType.hide,
                ),
                PlatformProvidedMenuItem(
                  type: PlatformProvidedMenuItemType.hideOtherApplications,
                ),
                PlatformProvidedMenuItem(
                  type: PlatformProvidedMenuItemType.showAllApplications,
                ),
              ],
            ),
            PlatformMenuItem(
              label: 'Quit PoDoFo',
              shortcut: const CharacterActivator('q', meta: true),
              // Use the window lifecycle to resolve unsaved document changes.
              onSelected: () => windowManager.close(),
            ),
          ],
        ),
        PlatformMenu(
          label: 'File',
          menus: [
            PlatformMenuItem(
              label: 'Open PDF',
              onSelected: () => ref.read(filePathProvider.notifier).pickFile(),
            ),
            PlatformMenuItem(
              label: 'Save',
              onSelected: document == null
                  ? null
                  : () => DocumentActions.save(context, ref, document),
            ),
            PlatformMenuItem(
              label: 'Save As…',
              onSelected: document == null
                  ? null
                  : () => DocumentActions.save(
                      context,
                      ref,
                      document,
                      saveAs: true,
                    ),
            ),
            PlatformMenuItem(
              label: 'Close tab',
              onSelected: document == null
                  ? null
                  : () => DocumentActions.close(context, ref, document),
            ),
          ],
        ),
        PlatformMenu(
          label: 'Edit',
          menus: [
            PlatformMenuItem(
              label: history.undoLabel,
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyZ,
                meta: true,
                includeRepeats: false,
              ),
              onSelected: history.canUndo
                  ? () => HistoryActions.resolve(ref).invoke(redo: false)
                  : null,
            ),
            PlatformMenuItem(
              label: history.redoLabel,
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyZ,
                meta: true,
                shift: true,
                includeRepeats: false,
              ),
              onSelected: history.canRedo
                  ? () => HistoryActions.resolve(ref).invoke(redo: true)
                  : null,
            ),
          ],
        ),
      ],
      child: content,
    );
  }
}
