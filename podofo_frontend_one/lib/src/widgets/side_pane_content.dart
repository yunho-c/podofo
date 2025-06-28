import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:podofo_one/src/providers.dart';

class SidePaneContent extends ConsumerWidget {
  const SidePaneContent({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activePane = ref.watch(sidePaneProvider);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: activePane == null ? 0 : 250,
      curve: Curves.easeInOut,
      child: activePane == null ? null : _buildContent(activePane),
    );
  }

  Widget _buildContent(SidePane pane) {
    switch (pane) {
      case SidePane.explorer:
        return const Center(child: Text('Explorer'));
      case SidePane.search:
        return const Center(child: Text('Search'));
      case SidePane.sourceControl:
        return const Center(child: Text('Source Control'));
      case SidePane.debug:
        return const Center(child: Text('Debug'));
      case SidePane.extensions:
        return const Center(child: Text('Extensions'));
    }
  }
}
