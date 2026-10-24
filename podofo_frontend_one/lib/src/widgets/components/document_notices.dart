import 'package:flutter/material.dart' as m;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/document_provider.dart';

class DocumentNotices extends ConsumerWidget {
  const DocumentNotices({super.key});
  @override
  m.Widget build(m.BuildContext context, WidgetRef ref) {
    final failures = ref.watch(documentFailuresProvider);
    final error = ref.watch(documentErrorProvider);
    if (failures.isEmpty && error == null) return const m.SizedBox.shrink();
    return m.Material(
      type: m.MaterialType.transparency,
      child: m.ConstrainedBox(
        constraints: const m.BoxConstraints(maxHeight: 170),
        child: m.SingleChildScrollView(
          child: m.Column(
            children: [
              if (error != null)
                m.ListTile(
                  title: m.Text(error, maxLines: 4),
                  trailing: m.IconButton(
                    tooltip: 'Dismiss',
                    icon: const m.Icon(m.Icons.close),
                    onPressed: () =>
                        ref.read(documentErrorProvider.notifier).state = null,
                  ),
                ),
              for (final entry in failures.entries)
                m.ListTile(
                  title: m.Text('Could not open ${entry.key}', maxLines: 2),
                  subtitle: m.Column(
                    crossAxisAlignment: m.CrossAxisAlignment.start,
                    children: [
                      m.Text(
                        entry.value,
                        maxLines: 2,
                        overflow: m.TextOverflow.ellipsis,
                      ),
                      m.Wrap(
                        children: [
                          m.TextButton(
                            onPressed: () => ref
                                .read(loadedDocumentsProvider.notifier)
                                .addDocument(entry.key),
                            child: const m.Text('Retry'),
                          ),
                          m.TextButton(
                            onPressed: () => ref
                                .read(filePathProvider.notifier)
                                .pickFile(recoveringPath: entry.key),
                            child: const m.Text('Locate PDF…'),
                          ),
                          m.TextButton(
                            onPressed: () => ref
                                .read(loadedDocumentsProvider.notifier)
                                .forgetUnavailable(entry.key),
                            child: const m.Text('Remove from session'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
