import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:podofo_one/src/providers.dart';
import 'package:podofo_one/src/tabs.dart';
import 'package:podofo_one/src/widgets/command_prompt.dart';
import 'package:podofo_one/src/widgets/main_content.dart';
import 'package:podofo_one/src/widgets/panes/activity_bar.dart';
import 'package:podofo_one/src/widgets/panes/pane_content.dart';
import 'package:podofo_one/src/widgets/tab_widget.dart';
import 'package:window_manager/window_manager.dart';

class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tabs = ref.watch(tabsProvider);
    final currentTabIndex = ref.watch(currentTabIndexProvider);
    final showCommandPrompt = ref.watch(commandPromptProvider);

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
                            .read(commandPromptProvider.notifier)
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
                            tab: tab,
                            isSelected: isSelected,
                            onTap: () => ref
                                .read(currentTabIndexProvider.notifier)
                                .state = index,
                            onClose: () {
                              ref.read(tabsProvider.notifier).state = [
                                for (int i = 0; i < tabs.length; i++)
                                  if (i != index) tabs[i],
                              ];
                              if (currentTabIndex >= tabs.length - 1) {
                                ref
                                    .read(currentTabIndexProvider.notifier)
                                    .state = tabs.length - 2;
                              }
                            },
                          );
                        },
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.brightness_6),
                      onPressed: () {
                        final currentTheme = ref.read(themeProvider);
                        ref.read(themeProvider.notifier).state =
                            currentTheme == ThemeMode.dark
                                ? ThemeMode.light
                                : ThemeMode.dark;
                      },
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Row(
                  children: [
                    ActivityBar(
                      provider: leftPaneProvider,
                      items: [
                        ActivityBarItem(
                          icon: Icons.description,
                          pane: LeftPane.explorer,
                        ),
                        ActivityBarItem(
                          icon: Icons.search,
                          pane: LeftPane.search,
                        ),
                        ActivityBarItem(
                          icon: Icons.source,
                          pane: LeftPane.sourceControl,
                        ),
                        ActivityBarItem(
                          icon: Icons.bug_report,
                          pane: LeftPane.debug,
                        ),
                        ActivityBarItem(
                          icon: Icons.extension,
                          pane: LeftPane.extensions,
                        ),
                      ],
                    ),
                    PaneContent(
                      provider: leftPaneProvider,
                      contentBuilder: (pane) {
                        switch (pane as LeftPane) {
                          case LeftPane.explorer:
                            return const Center(child: Text('Explorer'));
                          case LeftPane.search:
                            return const Center(child: Text('Search'));
                          case LeftPane.sourceControl:
                            return const Center(child: Text('Source Control'));
                          case LeftPane.debug:
                            return const Center(child: Text('Debug'));
                          case LeftPane.extensions:
                            return const Center(child: Text('Extensions'));
                        }
                      },
                    ),
                    const MainContent(),
                    PaneContent(
                      provider: rightPaneProvider,
                      contentBuilder: (pane) {
                        switch (pane as RightPane) {
                          case RightPane.outline:
                            return const Center(child: Text('Outline'));
                          case RightPane.timeline:
                            return const Center(child: Text('Timeline'));
                        }
                      },
                    ),
                    ActivityBar(
                      provider: rightPaneProvider,
                      items: [
                        ActivityBarItem(
                          icon: Icons.toc,
                          pane: RightPane.outline,
                        ),
                        ActivityBarItem(
                          icon: Icons.timeline,
                          pane: RightPane.timeline,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (showCommandPrompt) const CommandPrompt(),
        ],
      ),
    );
  }
}
