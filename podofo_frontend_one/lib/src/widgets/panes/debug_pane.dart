import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import 'package:podofo_one/src/providers/document_provider.dart';
import 'package:podofo_one/src/providers/user_state_provider.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import '../../services/context_menu_trace.dart';

class DebugPane extends ConsumerWidget {
  const DebugPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final userState = ref.watch(userStateNotifierProvider);
    final loadedDocuments = ref.watch(loadedDocumentsProvider);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(10.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(child: Text('Developer mode')),
              Semantics(
                label: 'Developer mode',
                child: Switch(
                  value: userState.developerMode,
                  onChanged: (value) => ref
                      .read(userStateNotifierProvider.notifier)
                      .setDeveloperMode(value),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const _ContextMenuDiagnostics(),
          const SizedBox(height: 16),
          Collapsible(
            children: [
              const CollapsibleTrigger(child: Text('Loaded Documents')),
              CollapsibleContent(
                child: OutlinedContainer(
                  child: Column(
                    children: [
                      for (final doc in loadedDocuments.values)
                        Text('${doc.title}: ${doc.lastOpenedPage ?? 'Not set'}')
                            .small(),
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
                  child: Column(children: [])
                      .withPadding(horizontal: 16, vertical: 8),
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
                      Text(userState.appearance),
                      const SizedBox(height: 10),
                      Button(
                        style: ButtonStyle.ghost(),
                        onPressed: () {
                          ref.read(userStateNotifierProvider.notifier).nuke();
                        },
                        child: const Text('Nuke User State'),
                      ),
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

class _ContextMenuDiagnostics extends ConsumerWidget {
  const _ContextMenuDiagnostics();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trace = ref.read(contextMenuTraceProvider);
    return ListenableBuilder(
      listenable: trace,
      builder: (context, _) => OutlinedContainer(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(child: Text('Trace right-clicks')),
                Semantics(
                  label: 'Trace right-clicks',
                  child: Switch(
                    value: trace.enabled,
                    onChanged: (value) => trace.enabled = value,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text('Enable, reproduce a missed click, then copy the trace.')
                .small(),
            Text(
              '${trace.length} events · ${trace.dropped} older events dropped',
            ).small().muted(),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                Button(
                  style: ButtonStyle.outline(),
                  onPressed: trace.length == 0
                      ? null
                      : () => Clipboard.setData(
                          ClipboardData(text: trace.export()),
                        ),
                  child: const Text('Copy trace'),
                ),
                Button(
                  style: ButtonStyle.outline(),
                  onPressed: trace.length == 0 ? null : trace.clear,
                  child: const Text('Clear trace'),
                ),
              ],
            ),
          ],
        ).withPadding(horizontal: 12, vertical: 10),
      ),
    );
  }
}
