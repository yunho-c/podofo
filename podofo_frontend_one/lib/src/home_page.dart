import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:podofo_one/src/providers.dart';
import 'package:podofo_one/src/tabs.dart';
import 'package:podofo_one/src/widgets/command_prompt.dart';
import 'package:podofo_one/src/widgets/main_content.dart';
import 'package:podofo_one/src/widgets/right_side_pane.dart';
import 'package:podofo_one/src/widgets/right_side_pane_content.dart';
import 'package:podofo_one/src/widgets/side_pane.dart';
import 'package:podofo_one/src/widgets/side_pane_content.dart';
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
                        ref.read(commandPromptProvider.notifier).update((state) => !state);
                      },
                      child: Container(
                        width: 200,
                        height: 20,
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.onSurface.withOpacity(0.2),
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
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: tabs.length,
                  itemBuilder: (context, index) {
                    final tab = tabs[index];
                    final isSelected = index == currentTabIndex;
                    return TabWidget(
                      tab: tab,
                      isSelected: isSelected,
                      onTap: () => ref.read(currentTabIndexProvider.notifier).state = index,
                      onClose: () {
                        ref.read(tabsProvider.notifier).state = [
                          for (int i = 0; i < tabs.length; i++)
                            if (i != index) tabs[i],
                        ];
                        if (currentTabIndex >= tabs.length - 1) {
                          ref.read(currentTabIndexProvider.notifier).state = tabs.length - 2;
                        }
                      },
                    );
                  },
                ),
              ),
              Expanded(
                child: Row(
                  children: [
                    const SidePaneWidget(),
                    const SidePaneContent(),
                    const MainContent(),
                    const RightSidePaneContent(),
                    const RightSidePaneWidget(),
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
