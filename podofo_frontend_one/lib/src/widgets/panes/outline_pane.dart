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

class OutlinePane extends ConsumerWidget {
  const OutlinePane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(pdfViewerControllerProvider);
    final document = ref.watch(currentDocumentProvider);

    if (document == null) {
      return const Center(child: Text('No document loaded'));
    }

    return FutureBuilder<List<PdfOutlineNode>>(
      future: document.pdfDocument.loadOutline(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(child: Text('Error: ${snapshot.error}'));
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final outline = snapshot.data!;
        if (outline.isEmpty) {
          return const Center(child: Text('No outline found'));
        }

        // return _OutlineTreeView(
        //   outline: outline,
        //   onNodeTap: (dest) => controller.goToDest(dest),
        // );

        final outlineTree = _pdfOutlineToTreeNodes(outline);

        return TreeView<PdfOutlineNode>(
          nodes: outlineTree,
          // expandIcon: expandIcon,
          shrinkWrap: true,
          // recursiveSelection: recursiveSelection,
          // branchLine: usePath ? BranchLine.path : BranchLine.line,
          // onSelectionChanged: TreeView.defaultSelectionHandler(
          //   treeItems,
          //   (value) {
          //     setState(() {
          //       treeItems = value;
          //     });
          //   },
          // ),
          builder: (context, node) {
            return TreeItemView(
              onPressed: () {},
              trailing: node.leaf
                  ? Container(
                      width: 16,
                      height: 16,
                      alignment: Alignment.center,
                      child: const CircularProgressIndicator(),
                    )
                  : null,
              leading: node.leaf
                  ? const Icon(BootstrapIcons.fileImage)
                  : Icon(
                      node.expanded
                          ? BootstrapIcons.folder2Open
                          : BootstrapIcons.folder2,
                    ),
              onExpand: TreeView.defaultItemExpandHandler(outlineTree, node, (
                value,
              ) {
                // setState(() {
                //   outlineTree = value;
                // });
              }),
              child: Text(node.data.title),
            );
          },
        );

        // return Text(outline.toString());
      },
    );
  }
}
