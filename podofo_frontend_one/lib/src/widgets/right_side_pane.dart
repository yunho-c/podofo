import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:podofo_one/src/providers.dart';

class RightSidePaneWidget extends ConsumerWidget {
  const RightSidePaneWidget({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activePane = ref.watch(rightSidePaneProvider);

    return Container(
      width: 50,
      color: Theme.of(context).colorScheme.surface.withOpacity(0.2),
      child: Column(
        children: [
          _buildIcon(ref, Icons.toc, RightSidePane.outline, activePane),
          _buildIcon(ref, Icons.timeline, RightSidePane.timeline, activePane),
        ],
      ),
    );
  }

  Widget _buildIcon(
    WidgetRef ref,
    IconData icon,
    RightSidePane pane,
    RightSidePane? activePane,
  ) {
    final bool isSelected = pane == activePane;
    return IconButton(
      icon: Icon(icon, color: isSelected ? Colors.white : Colors.grey),
      onPressed: () {
        if (isSelected) {
          ref.read(rightSidePaneProvider.notifier).state = null;
        } else {
          ref.read(rightSidePaneProvider.notifier).state = pane;
        }
      },
    );
  }
}
