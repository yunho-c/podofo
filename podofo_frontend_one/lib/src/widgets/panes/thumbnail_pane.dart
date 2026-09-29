import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:shadcn_flutter/shadcn_flutter.dart';

import '../../providers/document_provider.dart';
import '../../workers/thumbnail_worker.dart';

class ThumbnailPane extends ConsumerWidget {
  const ThumbnailPane({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final document = ref.watch(currentDocumentProvider);
    if (document == null) {
      return const Center(child: Text('No document loaded'));
    }
    return ListView.builder(
      key: ObjectKey(document.session),
      itemExtent: 290,
      scrollCacheExtent: const ScrollCacheExtent.pixels(300),
      itemCount: document.pdfDocument.pages.length,
      itemBuilder: (context, index) => Consumer(
        builder: (context, ref, _) {
          final thumbnail = ref.watch(
            thumbnailProvider((
              session: document.session,
              revision: document.session.revision,
              page: index + 1,
            )),
          );
          return Padding(
            padding: const EdgeInsets.all(8),
            child: Button(
              style: ButtonStyle.ghost(),
              onPressed: () {
                final controller = ref.read(pdfViewerControllerProvider);
                if (controller.isReady) {
                  controller.goToPage(pageNumber: index + 1);
                }
              },
              child: Column(
                children: [
                  Expanded(
                    child: thumbnail.when(
                      loading: () =>
                          const Center(child: CircularProgressIndicator()),
                      error: (e, s) =>
                          const Center(child: Text('Preview unavailable')),
                      data: (bytes) => bytes == null
                          ? const SizedBox()
                          : Image.memory(bytes, fit: BoxFit.contain),
                    ),
                  ),
                  Text('Page ${index + 1}'),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
