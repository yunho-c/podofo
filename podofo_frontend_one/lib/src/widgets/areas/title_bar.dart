import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:window_manager/window_manager.dart';

import 'package:podofo_one/src/providers/providers.dart';

class TitleBar extends ConsumerWidget {
  const TitleBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GestureDetector(
      onPanStart: (details) => windowManager.startDragging(),
      child: GestureDetector(
        onTap: () {
          ref.read(commandPaletteProvider.notifier).update((state) => !state);
        },
        child: SizedBox(
          height: 30,
          child: Center(
            child: Container(
              width: 200,
              height: 15,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.accent,
                borderRadius: BorderRadius.circular(5),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
