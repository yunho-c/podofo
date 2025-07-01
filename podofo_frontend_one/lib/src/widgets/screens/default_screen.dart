import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:window_manager/window_manager.dart';

import 'package:podofo_one/src/providers/providers.dart';
import 'package:podofo_one/src/providers/tab_provider.dart';
import 'package:podofo_one/src/widgets/components/command_palette.dart';
import 'package:podofo_one/src/widgets/areas/main_area.dart';
import 'package:podofo_one/src/widgets/areas/sidebar.dart';
import 'package:podofo_one/src/widgets/panes/pane_widget.dart';
import 'package:podofo_one/src/widgets/buttons/tab_widget.dart';
import 'package:podofo_one/src/data/pane_data.dart';

class DefaultScreen extends ConsumerWidget {
  const DefaultScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tabs = ref.watch(tabsProvider);
    final currentTabIndex = ref.watch(currentTabIndexProvider);
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
                        height: 20,
                        decoration: BoxDecoration(
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Container(
                height: 40,
                color: Theme.of(context).colorScheme.surface,
                child: Row(
                  children: [
                    Expanded(
                      child: ListView.builder(
                        scrollDirection: Axis.horizontal,
                        itemCount: tabs.length,
                        itemBuilder: (context, index) {
                          final tab = tabs[index];
                          final isSelected = index == currentTabIndex;
                          return TabWidget(
                            document: tab,
                            isSelected: isSelected,
                            onTap: () =>
                                ref
                                        .read(currentTabIndexProvider.notifier)
                                        .state =
                                    index,
                            onClose: () {
                              final oldTabsCount = tabs.length;
                              final oldTabIndex = currentTabIndex;

                              if (oldTabsCount == 1) {
                                ref
                                        .read(currentTabIndexProvider.notifier)
                                        .state =
                                    0;
                              } else if (index < oldTabIndex) {
                                ref
                                        .read(currentTabIndexProvider.notifier)
                                        .state =
                                    oldTabIndex - 1;
                              } else if (index == oldTabIndex &&
                                  oldTabIndex == oldTabsCount - 1) {
                                ref
                                        .read(currentTabIndexProvider.notifier)
                                        .state =
                                    oldTabIndex - 1;
                              }

                              ref
                                  .read(loadedDocumentsProvider.notifier)
                                  .removeDocument(tab.filePath);
                            },
                          );
                        },
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.brightness_6),
                      onPressed: () {
                        final currentTheme = ref.read(themeProvider);
                        ref
                            .read(themeProvider.notifier)
                            .state = currentTheme == ThemeMode.dark
                            ? ThemeMode.light
                            : ThemeMode.dark;
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.folder_open),
                      onPressed: () => {
                        ref.read(filePathProvider.notifier).pickFile(),
                      },
                    ),
                  ],
                ),
              ),
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
