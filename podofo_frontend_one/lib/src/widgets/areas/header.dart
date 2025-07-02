// import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'package:podofo_one/src/providers/providers.dart';
import 'package:podofo_one/src/providers/tab_provider.dart';
import 'package:podofo_one/src/widgets/buttons/tab_widget.dart';

class Header extends ConsumerWidget {
  const Header({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tabs = ref.watch(tabsProvider);
    final currentTabIndex = ref.watch(currentTabIndexProvider);
    return Container(
      height: 40,
      // color: Theme.of(context).colorScheme.surface, // material
      color: Theme.of(context).colorScheme.background, // shadcn
      // decoration: BoxDecoration(
      //   color: Theme.of(context).colorScheme.background,
      //   boxShadow: [
      //     BoxShadow(
      //       color: Colors.black.withAlpha(15),
      //       spreadRadius: 0,
      //       blurRadius: 5,
      //       offset: const Offset(1, 0),
      //     ),
      //   ],
      // ),
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
                      ref.read(currentTabIndexProvider.notifier).state = index,
                  onClose: () {
                    final oldTabsCount = tabs.length;
                    final oldTabIndex = currentTabIndex;

                    if (oldTabsCount == 1) {
                      ref.read(currentTabIndexProvider.notifier).state = 0;
                    } else if (index < oldTabIndex) {
                      ref.read(currentTabIndexProvider.notifier).state =
                          oldTabIndex - 1;
                    } else if (index == oldTabIndex &&
                        oldTabIndex == oldTabsCount - 1) {
                      ref.read(currentTabIndexProvider.notifier).state =
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
            variance: ButtonStyle.ghostIcon(),
          ),
          IconButton(
            icon: const Icon(Icons.folder_open),
            onPressed: () => {ref.read(filePathProvider.notifier).pickFile()},
            variance: ButtonStyle.ghostIcon(),
          ),
          IconButton(
            icon: const Icon(BootstrapIcons.magic),
            onPressed: () => {},
            variance: ButtonStyle.ghostIcon(),
          ),
          IconButton(
            icon: const Icon(Icons.more_horiz_outlined),
            onPressed: () => {},
            variance: ButtonStyle.ghostIcon(),
          ),
        ],
      ),
    );
  }
}
