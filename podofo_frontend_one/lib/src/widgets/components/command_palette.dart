import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'package:podofo_one/src/providers/document_provider.dart';
import 'package:podofo_one/src/providers/ui_provider.dart';

class CommandPalette extends ConsumerWidget {
  const CommandPalette({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Center(
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: theme.colorScheme.primary.withAlpha(40)),
          borderRadius: theme.borderRadiusXxl,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.1),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Command(
          builder: (context, query) async* {
            final history = await ref.read(documentHistoryProvider.future);
            final filteredHistory = history
                .where(
                  (doc) =>
                      query == null ||
                      p
                          .basename(doc.filePath)
                          .toLowerCase()
                          .contains(query.toLowerCase()),
                )
                .toList();

            if (filteredHistory.isNotEmpty) {
              final items = filteredHistory.map((doc) {
                return CommandItem(
                  title: Text(p.basename(doc.filePath)),
                  // subtitle: Text(
                  //   doc.filePath,
                  //   style: Theme.of(context).typography.small.muted,
                  //   overflow: TextOverflow.ellipsis,
                  // ),
                  leading: const Icon(Icons.description_outlined),
                  onTap: () {
                    ref
                        .read(loadedDocumentsProvider.notifier)
                        .addDocument(doc.filePath);
                    ref.read(commandPaletteProvider.notifier).state = false;
                  },
                );
              }).toList();
              yield [
                CommandCategory(
                  title: const Text('Recently Opened'),
                  children: items,
                ),
              ];
            }
          },
        ).sized(width: 600, height: 400),
      ),
    );
  }
}
