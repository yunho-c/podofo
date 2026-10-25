import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' as m;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:window_manager/window_manager.dart';

import '../../providers/document_provider.dart';
import '../../providers/ui_provider.dart';
import '../../services/document_actions.dart';

class TitleBar extends ConsumerWidget {
  const TitleBar({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final document = ref.watch(currentDocumentProvider);
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
        Expanded(child: child),
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
      ],
      child: content,
    );
  }
}
