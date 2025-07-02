import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'package:podofo_one/src/providers/providers.dart';
import 'package:podofo_one/src/providers/tab_provider.dart';
import 'package:podofo_one/src/providers/user_state_provider.dart';
import 'package:podofo_one/src/widgets/buttons/tab_widget.dart';
import 'package:podofo_one/src/widgets/components/hotkey_editor.dart';

class Header extends ConsumerWidget {
  const Header({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentTheme = ref.read(themeModeProvider);
    final currentTabIndex = ref.watch(currentTabIndexProvider);
    final tabs = ref.watch(tabsProvider);
    final userState = ref.watch(userStateNotifierProvider);
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
              itemCount: tabs.length + 1,
              itemBuilder: (context, index) {
                // HACK: one-off function to append icon to the right of
                //       the last tab.
                if (index == tabs.length) {
                  return IconButton(
                    icon: const Icon(BootstrapIcons.plus),
                    onPressed: () => {
                      ref.read(filePathProvider.notifier).pickFile(),
                    },
                    variance: ButtonStyle.ghostIcon(),
                  );
                }
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
            icon: FaIcon(
              FontAwesomeIcons.highlighter,
              color: userState.highlight
                  ? Colors.green
                  : Theme.of(context).colorScheme.foreground,
            ),
            onPressed: () {
              // final currentHighlight = userState.highlight;
              ref
                  .read(userStateNotifierProvider.notifier)
                  // .setHighlight(!currentHighlight);
                  .setHighlight(!userState.highlight);
            },
            variance: ButtonStyle.ghostIcon(),
          ),
          IconButton(
            icon: Icon(
              currentTheme == ThemeMode.dark
                  ? Icons.nightlight_outlined
                  : Icons.wb_sunny_outlined,
            ),
            onPressed: () {
              ref
                  .read(themeModeProvider.notifier)
                  .state = currentTheme == ThemeMode.dark
                  ? ThemeMode.light
                  : ThemeMode.dark;
            },
            variance: ButtonStyle.ghostIcon(),
          ),
          IconButton(
            icon: const Icon(BootstrapIcons.headphones),
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
                            subMenu: [
                              MenuButton(child: Text('Smart Rename')),
                              MenuButton(child: Text('Optimize File Size')),
                              MenuButton(
                                child: Text('Re-Draw Text Boundaries'),
                              ),
                              MenuButton(
                                enabled: false,
                                child: Text('Translate').xSmall.medium.muted,
                              ),
                              MenuButton(child: Text('Dynamic')),
                              MenuButton(child: Text('Static')),
                            ],
                          ),
                          MenuButton(
                            child: Text('Extensions'),
                            trailing: Text('⌘⌥E').xSmall.muted,
                          ),
                          MenuButton(
                            child: Text('Settings'),
                            trailing: Text('⌘⌥S').xSmall.muted,
                          ),
                          MenuButton(
                            child: Text('Hotkeys'),
                            trailing: Text('⌘⌥H').xSmall.muted,
                            onPressed: (context) => {
                              HotkeyEditor.show(context),
                            },
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
