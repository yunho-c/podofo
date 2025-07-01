import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'package:podofo_one/src/providers/providers.dart';
import 'package:podofo_one/src/widgets/components/command_palette.dart';
import 'package:podofo_one/src/widgets/areas/main_area.dart';
import 'package:podofo_one/src/widgets/areas/header.dart';
import 'package:podofo_one/src/widgets/areas/sidebar.dart';
import 'package:podofo_one/src/widgets/panes/pane_widget.dart';
import 'package:podofo_one/src/data/pane_data.dart';

class DefaultScreen extends ConsumerWidget {
  const DefaultScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final showCommandPalette = ref.watch(commandPaletteProvider);

    return Scaffold(
      body: Stack(
        children: [
          Column(
            children: [
              GestureDetector(
                onPanStart: (details) => windowManager.startDragging(),
                child: Container(
                  height: 30,
                  color: Theme.of(context).colorScheme.surface,
                  child: Center(
                    child: InkWell(
                      onTap: () {
                        ref
                            .read(commandPaletteProvider.notifier)
                            .update((state) => !state);
                      },
                      child: Container(
                        width: 200,
                        height: 15,
                        decoration: BoxDecoration(
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withAlpha(50),
                          borderRadius: BorderRadius.circular(5),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Header(),
              Expanded(
                child: Row(
                  children: [
                    SideBar(
                      provider: leftPaneProvider,
                      items: leftPaneData.items,
                    ),
                    PaneWidget(provider: leftPaneProvider),
                    const MainArea(),
                    PaneWidget(provider: rightPaneProvider),
                    SideBar(
                      provider: rightPaneProvider,
                      items: rightPaneData.items,
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (showCommandPalette) const CommandPalette(),
        ],
      ),
    );
  }
}
