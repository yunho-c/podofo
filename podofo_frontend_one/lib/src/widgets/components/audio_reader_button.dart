import 'package:flutter/material.dart' show Icons, Tooltip;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' hide Tooltip;

import '../../providers/document_provider.dart';
import '../../providers/narration_provider.dart';
import '../../services/narration_actions.dart';

class AudioReaderButton extends ConsumerWidget {
  const AudioReaderButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => Tooltip(
    message:
        ref.watch(narrationControllerProvider).unavailableReason ??
        'Read selected text',
    child: IconButton(
      icon: const Icon(Icons.volume_up_outlined),
      onPressed:
          ref.watch(currentDocumentProvider) != null &&
              ref.watch(narrationControllerProvider).available
          ? () => NarrationActions.readSelection(ref)
          : null,
      variance: ButtonStyle.ghostIcon(),
    ),
  );
}
