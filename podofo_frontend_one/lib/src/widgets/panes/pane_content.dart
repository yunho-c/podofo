import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class PaneContent extends ConsumerWidget {
  final StateProvider<dynamic> provider;
  final Widget Function(dynamic) contentBuilder;

  const PaneContent({
    super.key,
    required this.provider,
    required this.contentBuilder,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activePane = ref.watch(provider);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: activePane == null ? 0 : 250,
      curve: Curves.easeInOut,
      child: activePane == null ? null : contentBuilder(activePane),
    );
  }
}
