// import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

class SideBarItem {
  final Widget icon;
  final dynamic pane;

  SideBarItem({required this.icon, required this.pane});
}

class SideBar extends ConsumerWidget {
  final List<SideBarItem> items;
  final StateProvider<dynamic> provider;

  const SideBar({super.key, required this.items, required this.provider});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activePane = ref.watch(provider);

    return Container(
      width: 50,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.background,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(15),
            spreadRadius: 0,
            blurRadius: 5,
            offset: const Offset(1, 0),
          ),
        ],
      ),
      child: Column(
        children: items
            .map((item) => _buildIcon(ref, item.icon, item.pane, activePane))
            .toList(),
      ),
    );
  }

  Widget _buildIcon(
    WidgetRef ref,
    Widget icon,
    dynamic pane,
    dynamic activePane,
  ) {
    final bool isSelected = pane == activePane;
    return IconButton(
      icon: icon,
      onPressed: () {
        if (isSelected) {
          ref.read(provider.notifier).state = null;
        } else {
          ref.read(provider.notifier).state = pane;
        }
      },
      variance: ButtonStyle.ghostIcon(),
    );
  }
}
