import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class PaneWidget extends ConsumerWidget {
  final StateProvider<dynamic> provider;

  const PaneWidget({super.key, required this.provider});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activePane = ref.watch(provider);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: activePane == null ? 0 : 250,
      curve: Curves.easeInOut,
      child: activePane == null ? null : activePane,
    );
  }
}
