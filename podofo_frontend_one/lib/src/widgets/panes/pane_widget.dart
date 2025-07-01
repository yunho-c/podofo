// import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

class PaneWidget extends ConsumerWidget {
  final StateProvider<dynamic> provider;

  const PaneWidget({super.key, required this.provider});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activePane = ref.watch(provider);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: activePane == null ? 0 : 250,
      curve: Curves.easeOutExpo,
      child: activePane == null ? null : activePane,
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
    );
  }
}
