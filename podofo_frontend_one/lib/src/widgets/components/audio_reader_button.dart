import 'package:flutter/material.dart' as m;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' hide Tooltip;

import '../../providers/document_provider.dart';
import '../../providers/narration_provider.dart';
import '../../services/narration_actions.dart';

class AudioReaderButton extends ConsumerWidget {
  const AudioReaderButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final narration = ref.watch(narrationControllerProvider);
    final document = ref.watch(currentDocumentProvider);
    return m.PopupMenuButton<String>(
      tooltip: narration.unavailableReason ?? 'Listen to paper',
      enabled: narration.available && document != null,
      icon: const Icon(m.Icons.volume_up_outlined),
      itemBuilder: (_) => const [
        m.PopupMenuItem(value: 'selection', child: Text('Read selected text')),
        m.PopupMenuItem(value: 'page', child: Text('Read from current page')),
        m.PopupMenuItem(
          value: 'beginning',
          child: Text('Read paper from beginning'),
        ),
        m.PopupMenuItem(value: 'resume', child: Text('Resume listening')),
      ],
      onSelected: (value) {
        switch (value) {
          case 'selection':
            NarrationActions.readSelection(ref);
          case 'page':
            NarrationActions.readPaper(ref);
          case 'beginning':
            NarrationActions.readPaper(ref, page: 1);
          case 'resume':
            NarrationActions.readPaper(ref, resume: true);
        }
      },
    );
  }
}
