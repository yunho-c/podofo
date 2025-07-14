import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:podofo_one/src/providers/document_provider.dart';
import 'package:podofo_one/src/providers/user_state_provider.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

class DebugPane extends ConsumerWidget {
  const DebugPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final userState = ref.watch(userStateNotifierProvider);
    final loadedDocuments = ref.watch(loadedDocumentsProvider);
    return Container(
      padding: const EdgeInsets.all(10.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Collapsible(
            children: [
              const CollapsibleTrigger(child: Text('Loaded Documents')),
              CollapsibleContent(
                child: OutlinedContainer(
                  child: Column(
                    children: [
                      for (final doc in loadedDocuments.values)
                        Text(
                          '${doc.title}: ${doc.lastOpenedPage ?? 'Not set'}',
                        ).small(),
                    ],
                  ).withPadding(horizontal: 16, vertical: 8),
                ).withPadding(top: 8),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Collapsible(
            children: [
              const CollapsibleTrigger(child: Text('Dark Mode')),
              CollapsibleContent(
                child: OutlinedContainer(
                  child: Column(
                    children: [],
                  ).withPadding(horizontal: 16, vertical: 8),
                ).withPadding(top: 8),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Collapsible(
            children: [
              const CollapsibleTrigger(child: Text('User State')),
              CollapsibleContent(
                child: OutlinedContainer(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Selected Text').small(),
                      Text(
                        '${userState.selectedText}',
                        maxLines: 5,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text('Highlight Mode Enabled').small(),
                      Text('${userState.highlightModeEnabled}'),
                      Text('Highlight Active Color Index').small(),
                      Text('${userState.highlightActiveColorIndex}'),
                      Text('Appearance').small(),
                      Text('${userState.appearance}'),
                    ],
                  ).withPadding(horizontal: 16, vertical: 8),
                ).withPadding(top: 8),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
