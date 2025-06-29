import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ActivityBarItem {
  final IconData icon;
  final dynamic pane;

  ActivityBarItem({required this.icon, required this.pane});
}

class ActivityBar extends ConsumerWidget {
  final List<ActivityBarItem> items;
  final StateProvider<dynamic> provider;

  const ActivityBar({super.key, required this.items, required this.provider});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activePane = ref.watch(provider);

    return Container(
      width: 50,
      color: Theme.of(context).colorScheme.surface.withOpacity(0.2),
      child: Column(
        children: items
            .map((item) => _buildIcon(ref, item.icon, item.pane, activePane))
            .toList(),
      ),
    );
  }

  Widget _buildIcon(
    WidgetRef ref,
    IconData icon,
    dynamic pane,
    dynamic activePane,
  ) {
    final bool isSelected = pane == activePane;
    return IconButton(
      icon: Icon(icon, color: isSelected ? Colors.white : Colors.grey),
      onPressed: () {
        if (isSelected) {
          ref.read(provider.notifier).state = null;
        } else {
          ref.read(provider.notifier).state = pane;
        }
      },
    );
  }
}
