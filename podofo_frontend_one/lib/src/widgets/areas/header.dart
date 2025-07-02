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
              final currentTheme = ref.read(themeModeProvider);
              ref
                  .read(themeModeProvider.notifier)
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
          Builder(
            builder: (context) {
              return IconButton(
                icon: const Icon(Icons.more_vert_rounded),
                variance: ButtonStyle.ghostIcon(),
                onPressed: () {
                  final RenderBox renderBox =
                      context.findRenderObject() as RenderBox;
                  final Offset offset = renderBox.localToGlobal(Offset.zero);
                  showDropdown(
                    context: context,
                    position: offset,
                    builder: (context) {
                      return DropdownMenu(
                        children: [
                          // MenuDivider(),
                          MenuButton(
                            child: Text('Utilities'),
                            trailing: Text('⌘⌥U').xSmall.muted,
                          ),
                          MenuButton(
                            child: Text('Extensions'),
                            trailing: Text('⌘⌥E').xSmall.muted,
                          ),
                          MenuButton(
                            child: Text('Settings'),
                            trailing: Text('⌘⌥S').xSmall.muted,
                          ),
                          MenuDivider(),
                          // MenuButton(
                          //   subMenu: [
                          MenuButton(
                            enabled: false,
                            child: Text('Community').xSmall.medium.muted,
                          ),
                          MenuButton(child: Text('Bug Tracker')),
                          MenuButton(child: Text('Discord')),
                          //   ],
                          //   child: Text('Community'),
                          // ),
                          MenuButton(child: Text('GitHub')),
                          MenuButton(child: Text('Blog')),
                          MenuDivider(),
                          // MenuButton(
                          //   enabled: false,
                          //   child: Text(
                          //     'Thank you for using PoDoFo!',
                          //   ).xSmall.medium.muted,
                          // ),
                          MenuLabel(child: Text('PoDoFo')),
                          MenuLabel(child: Text('Version X.X.X').xSmall.muted),
                          MenuButton(child: Text('Donate')),
                          MenuButton(child: Text('Contributors')),
                          MenuButton(child: Text('Open-Source')),
                        ],
                      );
                    },
                  ).future.then((_) {
                    print('Closed');
                  });
                },
              );
            },
          ),
        ],
      ),
    );
  }
}
