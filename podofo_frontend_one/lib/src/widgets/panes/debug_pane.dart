import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:podofo_one/src/providers/providers.dart';
import 'package:podofo_one/src/providers/user_state_provider.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

class DebugPane extends ConsumerWidget {
  const DebugPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final userState = ref.watch(userStateNotifierProvider);
    final shaderStrength = ref.watch(shaderStrengthProvider);
    final loadedDocuments = ref.watch(loadedDocumentsProvider);
    return Container(
      padding: const EdgeInsets.all(10.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Collapsible(
              children: [
                const CollapsibleTrigger(child: Text('Loaded Documents')),
                CollapsibleContent(
                  child: OutlinedContainer(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
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
          ),
          Expanded(
            child: Collapsible(
              children: [
                const CollapsibleTrigger(child: Text('Dark Mode')),
                CollapsibleContent(
                  child: OutlinedContainer(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [],
                    ).withPadding(horizontal: 16, vertical: 8),
                  ).withPadding(top: 8),
                ),
              ],
            ),
          ),
          Expanded(
            child: Collapsible(
              children: [
                const CollapsibleTrigger(child: Text('User State')),
                CollapsibleContent(
                  child: OutlinedContainer(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Highlight').small(),
                        Text('${userState.highlight}'),
                        Text('Appearance').small(),
                        Text('${userState.appearance}'),
                      ],
                    ).withPadding(horizontal: 16, vertical: 8),
                  ).withPadding(top: 8),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
