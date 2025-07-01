// import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'package:podofo_one/src/providers/providers.dart';

List<TreeNode<PdfOutlineNode>> _pdfOutlineToTreeNodes(
  List<PdfOutlineNode> nodes,
) {
  return [
    for (final node in nodes)
      TreeItem(
        data: node,
        children: node.children.isNotEmpty
            ? _pdfOutlineToTreeNodes(node.children)
            : [],
      ),
  ];
}

class OutlinePane extends ConsumerStatefulWidget {
  const OutlinePane({super.key});

  @override
  ConsumerState<OutlinePane> createState() => _OutlinePaneState();
}

class _OutlinePaneState extends ConsumerState<OutlinePane> {
  List<TreeNode<PdfOutlineNode>>? _treeNodes;

  @override
  Widget build(BuildContext context) {
    final outline = ref.watch(outlineProvider);

    if (outline.isLoading) {
      _treeNodes = null;
      return const Center(child: CircularProgressIndicator());
    }

    if (outline.hasError) {
      _treeNodes = null;
      return Center(child: Text('Error: ${outline.error}'));
    }

    final outlineData = outline.value;

    if (outlineData == null || outlineData.isEmpty) {
      _treeNodes = null;
      return const Center(child: Text('No outline found'));
    }

    _treeNodes ??= _pdfOutlineToTreeNodes(outlineData);

    return Align(
      alignment: Alignment.topCenter,
      child: TreeView<PdfOutlineNode>(
        nodes: _treeNodes!,
        expandIcon: true,
        // shrinkWrap: true,
        shrinkWrap: false,
        builder: (context, node) {
          return TreeItemView(
            onPressed: () {
              if (node.data.dest != null) {
                ref.read(pdfViewerControllerProvider).goToDest(node.data.dest!);
              }
            },
            // leading: node.leaf
            //     ? const Icon(BootstrapIcons.dot)
            //     : Icon(
            //         node.expanded
            //             ? BootstrapIcons.folder2Open
            //             : BootstrapIcons.folder2,
            //       ),
            trailing: null,
            onExpand: TreeView.defaultItemExpandHandler(_treeNodes!, node, (
              value,
            ) {
              setState(() {
                _treeNodes = value;
              });
            }),
            child: Text(
              node.data.title.trim(),
              style: TextStyle(color: Theme.of(context).colorScheme.primary),
            ),
          );
        },
      ),
    );
  }
}
