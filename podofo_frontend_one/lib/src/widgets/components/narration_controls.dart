import 'package:flutter/material.dart' show Icons, Tooltip;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' hide Tooltip;

import '../../providers/narration_provider.dart';

class NarrationControls extends ConsumerWidget {
  const NarrationControls({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(narrationControllerProvider);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (controller.source == null &&
            !controller.preparing &&
            controller.error == null) {
          return const SizedBox.shrink();
        }
        return Container(
          key: const ValueKey('narration-controls'),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.background,
            border: Border(
              top: BorderSide(color: Theme.of(context).colorScheme.border),
            ),
          ),
          child: Row(
            children: [
              if (controller.preparing)
                const Padding(
                  padding: EdgeInsets.only(right: 12),
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(),
                  ),
                ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      controller.source?.title ?? 'Listen to your paper',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ).small(),
                    Text(
                      controller.status,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ).small().muted(),
                  ],
                ),
              ),
              Tooltip(
                message: controller.paused || controller.terminal
                    ? 'Play'
                    : 'Pause',
                child: IconButton(
                  key: const ValueKey('narration-play-pause'),
                  icon: Icon(
                    controller.paused || controller.terminal
                        ? Icons.play_arrow_rounded
                        : Icons.pause_rounded,
                  ),
                  variance: ButtonStyle.ghostIcon(),
                  onPressed: controller.source != null || controller.preparing
                      ? controller.togglePause
                      : null,
                ),
              ),
              Tooltip(
                message: 'Stop reading',
                child: IconButton(
                  key: const ValueKey('narration-stop'),
                  icon: const Icon(Icons.stop_rounded),
                  variance: ButtonStyle.ghostIcon(),
                  onPressed: controller.active ? controller.stop : null,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
