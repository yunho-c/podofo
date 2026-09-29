import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'package:podofo_one/src/providers/document_provider.dart';

List<TreeNode<PdfOutlineNode>> _pdfOutlineToTreeNodes(
  List<PdfOutlineNode> nodes,
) => [
  for (final node in nodes)
    TreeItemNode(data: node, children: _pdfOutlineToTreeNodes(node.children)),
];

class OutlinePane extends ConsumerStatefulWidget {
  const OutlinePane({super.key});

  @override
  ConsumerState<OutlinePane> createState() => _OutlinePaneState();
}

class _OutlinePaneState extends ConsumerState<OutlinePane> {
  List<PdfOutlineNode>? _source;
  List<TreeNode<PdfOutlineNode>>? _treeNodes;

  Future<void> _navigate(PdfOutlineNode node) async {
    final destination = node.dest;
    if (destination == null) return;
    final controller = ref.read(pdfViewerControllerProvider);
    if (!controller.isReady) return;
    try {
      await controller.goToDest(destination);
    } catch (error) {
      if (mounted) {
        ref.read(documentErrorProvider.notifier).state = error.toString();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final outline = ref.watch(outlineProvider);
    if (outline.isLoading || outline.hasError) {
      _source = null;
      _treeNodes = null;
      return Center(
        child: outline.hasError
            ? Text('Error: ${outline.error}')
            : const CircularProgressIndicator(),
      );
    }

    final nodes = outline.value;
    if (nodes == null || nodes.isEmpty) {
      _source = null;
      _treeNodes = null;
      return const Center(child: Text('No outline found'));
    }
    if (!identical(nodes, _source)) {
      _source = nodes;
      _treeNodes = _pdfOutlineToTreeNodes(nodes);
    }

    return Align(
      alignment: Alignment.topCenter,
      child: Tree<PdfOutlineNode>(
        key: ObjectKey(nodes),
        nodes: _treeNodes!,
        expandIcon: true,
        shrinkWrap: false,
        builder: (context, node) => TreeItem(
          // Group headings still need focus and keyboard expansion even when
          // the PDF supplies no navigation destination for the heading itself.
          onPressed: () => _navigate(node.data),
          onExpand: Tree.defaultItemExpandHandler(_treeNodes!, node, (value) {
            setState(() => _treeNodes = value);
          }),
          child: Text(
            node.data.title.trim(),
            style: TextStyle(color: Theme.of(context).colorScheme.primary),
          ),
        ),
      ),
    );
  }
}
