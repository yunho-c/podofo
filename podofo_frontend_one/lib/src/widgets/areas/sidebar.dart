// import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

class SideBarItem {
  final Widget icon;
  final dynamic pane;
  final String name;

  SideBarItem({required this.icon, required this.pane, required this.name});
}

class SideBar extends ConsumerWidget {
  final List<SideBarItem> items;
  final StateProvider<SideBarItem?> provider;

  const SideBar({super.key, required this.items, required this.provider});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activeItem = ref.watch(provider);

    return Container(
      width: 50,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.background,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(15),
            spreadRadius: 0,
            blurRadius: 10,
            offset: const Offset(1, 0),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Column(
          spacing: 2.0,
          children: items
              .map((item) => _buildIcon(ref, item, activeItem))
              .toList(),
        ),
      ),
    );
  }

  Widget _buildIcon(WidgetRef ref, SideBarItem item, SideBarItem? activeItem) {
    final bool isSelected = item == activeItem;
    return IconButton(
      icon: item.icon,
      onPressed: () {
        if (isSelected) {
          ref.read(provider.notifier).state = null;
        } else {
          ref.read(provider.notifier).state = item;
        }
      },
      variance: ButtonStyle.ghostIcon(),
    );
  }
}
