import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'package:podofo_one/src/providers/providers.dart';
import 'package:podofo_one/src/providers/tab_provider.dart';
import 'package:podofo_one/src/widgets/buttons/tab_widget.dart';
import 'package:podofo_one/src/widgets/components/dark_mode_button.dart';
import 'package:podofo_one/src/widgets/components/dropdowns.dart';
import 'package:podofo_one/src/widgets/components/highlight_button.dart';

class Header extends ConsumerWidget {
  const Header({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentTabIndex = ref.watch(currentTabIndexProvider);
    final tabs = ref.watch(tabsProvider);
    return Container(
      height: 40,
      color: Theme.of(context).colorScheme.background,
      child: Row(
        children: [
          Container(
            padding: EdgeInsets.fromLTRB(7.5, 2, 7.5, 2),
            child: IconButton(
              icon: const Icon(Icons.home_outlined),
              onPressed: () => {},
              variance: ButtonStyle.ghostIcon(),
              size: ButtonSize.normal,
            ),
          ),
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: tabs.length + 1,
              itemBuilder: (context, index) {
                // HACK: one-off function to append icon to the right of
                //       the last tab.
                if (index == tabs.length) {
                  return Container(
                    padding: EdgeInsets.all(2),
                    child: IconButton(
                      icon: const Icon(BootstrapIcons.plus),
                      onPressed: () => {
                        ref.read(filePathProvider.notifier).pickFile(),
                      },
                      variance: ButtonStyle.ghostIcon(),
                    ),
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
          HighlightButton(),
          const DarkModeButton(),
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
                      return moreOptionsDropdown;
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
