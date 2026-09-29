import 'dart:io';

import 'package:flutter/material.dart' as m;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:window_manager/window_manager.dart';

import '../../providers/document_provider.dart';
import '../../providers/ui_provider.dart';
import '../../services/document_actions.dart';
import '../../services/windows_title_bar.dart';

class TitleBar extends ConsumerWidget {
  const TitleBar({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final document = ref.watch(currentDocumentProvider);
    final content = ValueListenableBuilder<WindowsTitleBarMetrics>(
      valueListenable: WindowsTitleBar.instance,
      builder: (context, metrics, _) {
        WindowsTitleBar.instance.setBrightness(
          Theme.of(context).colorScheme.brightness,
        );
        return Column(
          children: [
            SizedBox(
              height: metrics.height,
              child: Row(
                children: [
                  SizedBox(
                    width: 80,
                    child: m.PopupMenuButton<String>(
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
                    child: Row(
                      children: [
                        const Expanded(child: _TitleBarDragArea()),
                        SizedBox(
                          width: 200,
                          child: Column(
                            children: [
                              const Expanded(child: _TitleBarDragArea()),
                              Semantics(
                                label: 'Recent files',
                                button: true,
                                child: GestureDetector(
                                  onTap: () => ref
                                      .read(commandPaletteProvider.notifier)
                                      .update((value) => !value),
                                  child: Container(
                                    height: 15,
                                    width: 200,
                                    decoration: BoxDecoration(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .accent,
                                      borderRadius: BorderRadius.circular(5),
                                    ),
                                  ),
                                ),
                              ),
                              const Expanded(child: _TitleBarDragArea()),
                            ],
                          ),
                        ),
                        const Expanded(child: _TitleBarDragArea()),
                      ],
                    ),
                  ),
                  if (metrics.native)
                    SizedBox(width: metrics.buttonsWidth)
                  else if (!Platform.isMacOS)
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
      },
    );
    if (!Platform.isMacOS) return content;
    return PlatformMenuBar(
      menus: [
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
              label: 'Quit',
              onSelected: () => windowManager.close(),
            ),
          ],
        ),
      ],
      child: content,
    );
  }
}

// Keep title bar gestures off interactive controls so double-click recognition
// does not delay the File menu or command palette's ordinary clicks.
class _TitleBarDragArea extends StatelessWidget {
  const _TitleBarDragArea();

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onPanStart: (_) => windowManager.startDragging(),
    onDoubleTap: () async {
      if (await windowManager.isMaximized()) {
        await windowManager.unmaximize();
      } else {
        await windowManager.maximize();
      }
    },
    onSecondaryTapUp: Platform.isWindows
        ? (_) => windowManager.popUpWindowMenu()
        : null,
    child: const SizedBox.expand(),
  );
}
