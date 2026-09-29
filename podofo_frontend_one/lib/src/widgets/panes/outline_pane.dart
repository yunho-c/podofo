import 'package:flutter/material.dart' show Icons;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'package:podofo_one/src/providers/document_provider.dart';

class OutlinePane extends ConsumerWidget {
  const OutlinePane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final document = ref.watch(currentDocumentProvider);
    return ref
        .watch(outlineProvider)
        .when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) =>
              Center(child: Text('Unable to load outline: $error')),
          data: (nodes) => nodes.isEmpty
              ? const Center(child: Text('No outline found'))
              : ListView(
                  key: ValueKey(document?.filePath),
                  children: [
                    for (final node in nodes) _OutlineEntry(node: node),
                  ],
                ),
        );
  }
}

class _OutlineEntry extends ConsumerStatefulWidget {
  const _OutlineEntry({required this.node});
  final PdfOutlineNode node;

  @override
  ConsumerState<_OutlineEntry> createState() => _OutlineEntryState();
}

class _OutlineEntryState extends ConsumerState<_OutlineEntry> {
  bool expanded = false;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          if (widget.node.children.isNotEmpty)
            IconButton(
              icon: Icon(expanded ? Icons.expand_less : Icons.expand_more),
              variance: ButtonStyle.ghostIcon(),
              onPressed: () => setState(() => expanded = !expanded),
            ),
          Expanded(
            child: Button.ghost(
              alignment: Alignment.centerLeft,
              onPressed: widget.node.dest == null
                  ? null
                  : () {
                      final controller = ref.read(pdfViewerControllerProvider);
                      if (controller.isReady) {
                        controller.goToDest(widget.node.dest!);
                      }
                    },
              child: Text(widget.node.title.trim()),
            ),
          ),
        ],
      ),
      if (expanded)
        Padding(
          padding: const EdgeInsets.only(left: 16),
          child: Column(
            children: [
              for (final node in widget.node.children)
                _OutlineEntry(node: node),
            ],
          ),
        ),
    ],
  );
}
