import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:podofo_one/src/tabs.dart';

class MainContent extends ConsumerWidget {
  const MainContent({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tabs = ref.watch(tabsProvider);
    final currentTabIndex = ref.watch(currentTabIndexProvider);

    return Expanded(
      child: IndexedStack(
        index: currentTabIndex,
        children: tabs.map((tab) => tab.child).toList(),
      ),
    );
  }
}
