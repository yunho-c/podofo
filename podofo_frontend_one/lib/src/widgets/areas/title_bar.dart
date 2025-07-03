import 'dart:io' show Platform;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart' show SubmenuButton, MenuItemButton;
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:window_manager/window_manager.dart';

import 'package:podofo_one/src/providers/providers.dart';

class TitleBar extends ConsumerWidget {
  final Widget child;
  const TitleBar({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (Platform.isMacOS) {
      return PlatformMenuBar(
        menus: <PlatformMenuItem>[
          PlatformMenu(
            label: 'PoDoFo',
            menus: <PlatformMenuItem>[
              PlatformMenuItem(
                label: '?1',
                onSelected: () {
                  ref.read(filePathProvider.notifier).pickFile();
                },
              ),
            ],
          ),
          PlatformMenu(
            label: 'File',
            menus: <PlatformMenuItem>[
              PlatformMenuItem(
                label: 'Open File',
                onSelected: () {
                  ref.read(filePathProvider.notifier).pickFile();
                },
              ),
              PlatformMenuItem(
                label: 'Save',
                onSelected: () {
                  ref.read(filePathProvider.notifier).pickFile();
                },
              ),
              PlatformMenuItem(
                label: 'Save as...',
                onSelected: () {
                  ref.read(filePathProvider.notifier).pickFile();
                },
              ),
              PlatformMenuItem(
                label: 'Export',
                onSelected: () {
                  ref.read(filePathProvider.notifier).pickFile();
                },
              ),
              PlatformMenuItem(
                label: 'Print',
                onSelected: () {
                  ref.read(filePathProvider.notifier).pickFile();
                },
              ),
            ],
          ),
          PlatformMenu(
            label: 'Edit',
            menus: <PlatformMenuItem>[
              PlatformMenuItem(label: 'Undo', onSelected: () {}),
              PlatformMenuItem(label: 'Redo', onSelected: () {}),
            ],
          ),
          PlatformMenu(
            label: 'View',
            menus: <PlatformMenuItem>[
              PlatformMenuItem(label: 'Reset zoom', onSelected: () {}),
            ],
          ),
          PlatformMenu(
            label: 'Window',
            menus: <PlatformMenuItem>[
              PlatformMenuItem(label: 'umm', onSelected: () {}),
            ],
          ),
          PlatformMenu(
            label: 'Help',
            menus: <PlatformMenuItem>[
              PlatformMenuItem(label: 'jun', onSelected: () {}),
            ],
          ),
        ],
        child: Column(
          children: [
            GestureDetector(
              onPanStart: (details) => windowManager.startDragging(),
              child: SizedBox(
                height: 30,
                child: GestureDetector(
                  onTap: () {
                    ref
                        .read(commandPaletteProvider.notifier)
                        .update((state) => !state);
                  },
                  child: Center(
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
            Expanded(child: child),
          ],
        ),
      );
    } else {
      final menu = SubmenuButton(
        menuChildren: <Widget>[
          MenuItemButton(
            onPressed: () {
              ref.read(filePathProvider.notifier).pickFile();
            },
            child: const Text('Open File'),
          ),
        ],
        child: const Text('File'),
      );

      return Column(
        children: [
          GestureDetector(
            onPanStart: (details) => windowManager.startDragging(),
            child: Container(
              height: 30,
              child: Row(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8.0),
                    child: menu,
                  ),
                  Expanded(
                    child: Center(
                      child: GestureDetector(
                        onTap: () {
                          ref
                              .read(commandPaletteProvider.notifier)
                              .update((state) => !state);
                        },
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
                ],
              ),
            ),
          ),
          Expanded(child: child),
        ],
      );
    }
  }
}
