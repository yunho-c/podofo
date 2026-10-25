import 'package:flutter/material.dart' as m;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/document_provider.dart';
import '../../editing/annotation_edit.dart';
import '../../services/pdf_session.dart';
import '../../services/document_actions.dart';

typedef _PageRequest = ({PdfSession session, int revision, int page});
final _pageAnnotations = FutureProvider.autoDispose
    .family<List<AnnotationRecord>, _PageRequest>((ref, request) async {
      return (await request.session.annotations())
          .where((record) => record.pageNumber == request.page)
          .toList();
    });

class AnnotationPane extends ConsumerWidget {
  const AnnotationPane({super.key});
  @override
  m.Widget build(m.BuildContext context, WidgetRef ref) {
    final document = ref.watch(currentDocumentProvider);
    if (document == null) {
      return const m.Center(child: m.Text('No document loaded'));
    }
    final revision = document.session.revision;
    return m.Material(
      type: m.MaterialType.transparency,
      child: m.ListView.builder(
        key: m.ObjectKey(document.session),
        itemCount: document.pdfDocument.pages.length,
        itemBuilder: (context, index) => Consumer(
          builder: (context, ref, _) {
            final annotations = ref.watch(
              _pageAnnotations((
                session: document.session,
                revision: revision,
                page: index + 1,
              )),
            );
            return m.Padding(
              padding: const m.EdgeInsets.all(8),
              child: m.Column(
                crossAxisAlignment: m.CrossAxisAlignment.stretch,
                children: [
                  m.Text(
                    'Page ${index + 1}',
                    style: const m.TextStyle(fontWeight: m.FontWeight.bold),
                  ),
                  annotations.when(
                    loading: () => const m.Text('Loading annotations…'),
                    error: (e, s) => const m.Text('Could not read annotations'),
                    data: (items) => items.isEmpty
                        ? const m.Text('No annotations')
                        : m.Column(
                            children: [
                              for (final item in items)
                                m.ListTile(
                                  dense: true,
                                  contentPadding: m.EdgeInsets.zero,
                                  title: m.Text(
                                    item.contents.isEmpty
                                        ? item.kind.label
                                        : item.contents,
                                    maxLines: 3,
                                    overflow: m.TextOverflow.ellipsis,
                                  ),
                                  onTap: () {
                                    final controller = ref.read(
                                      pdfViewerControllerProvider,
                                    );
                                    if (controller.isReady) {
                                      controller.goToPage(
                                        pageNumber: index + 1,
                                      );
                                    }
                                  },
                                  trailing: m.IconButton(
                                    tooltip: item.owned
                                        ? 'Remove ${item.kind.name}'
                                        : 'Only PoDoFo annotations can be edited',
                                    icon: const m.Icon(m.Icons.delete_outline),
                                    onPressed:
                                        !item.canEdit ||
                                            document
                                                    .pdfDocument
                                                    .permissions
                                                    ?.allowsModifyAnnotations ==
                                                false
                                        ? null
                                        : () async {
                                            final notifier = ref.read(
                                              loadedDocumentsProvider.notifier,
                                            );
                                            try {
                                              await notifier.removeAnnotations(
                                                document,
                                                {item.id},
                                                revision,
                                              );
                                            } catch (e) {
                                              if (context.mounted) {
                                                DocumentActions.error(ref, e);
                                              }
                                            }
                                          },
                                  ),
                                ),
                            ],
                          ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
