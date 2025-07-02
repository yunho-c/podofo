import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'package:podofo_one/src/widgets/areas/sidebar.dart';

class PaneWidget extends ConsumerWidget {
  final StateProvider<SideBarItem?> provider;

  const PaneWidget({super.key, required this.provider});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activeItem = ref.watch(provider);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: activeItem == null ? 0 : 250,
      curve: Curves.easeInOutCirc,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.background,
      ),
      child: activeItem == null
          ? null
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Text(
                    activeItem.name,
                    style: Theme.of(context).typography.xSmall.copyWith(
                      color: Theme.of(context).colorScheme.mutedForeground,
                    ),
                  ).semiBold(),
                ),
                Expanded(child: activeItem.pane),
              ],
            ),
    );
  }
}
