import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:podofo_one/src/providers.dart';

class RightSidePaneContent extends ConsumerWidget {
  const RightSidePaneContent({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activePane = ref.watch(rightSidePaneProvider);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: activePane == null ? 0 : 250,
      curve: Curves.easeInOut,
      child: activePane == null ? null : _buildContent(activePane),
    );
  }

  Widget _buildContent(RightSidePane pane) {
    switch (pane) {
      case RightSidePane.outline:
        return const Center(child: Text('Outline'));
      case RightSidePane.timeline:
        return const Center(child: Text('Timeline'));
    }
  }
}
