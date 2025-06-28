import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:podofo_one/src/providers.dart';

class SidePaneWidget extends ConsumerWidget {
  const SidePaneWidget({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activePane = ref.watch(sidePaneProvider);

    return Container(
      width: 50,
      color: Theme.of(context).colorScheme.surface.withOpacity(0.2),
      child: Column(
        children: [
          _buildIcon(ref, Icons.description, SidePane.explorer, activePane),
          _buildIcon(ref, Icons.search, SidePane.search, activePane),
          _buildIcon(ref, Icons.source, SidePane.sourceControl, activePane),
          _buildIcon(ref, Icons.bug_report, SidePane.debug, activePane),
          _buildIcon(ref, Icons.extension, SidePane.extensions, activePane),
        ],
      ),
    );
  }

  Widget _buildIcon(
    WidgetRef ref,
    IconData icon,
    SidePane pane,
    SidePane? activePane,
  ) {
    final bool isSelected = pane == activePane;
    return IconButton(
      icon: Icon(icon, color: isSelected ? Colors.white : Colors.grey),
      onPressed: () {
        if (isSelected) {
          ref.read(sidePaneProvider.notifier).state = null;
        } else {
          ref.read(sidePaneProvider.notifier).state = pane;
        }
      },
    );
  }
}
