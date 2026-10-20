import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../narration/narration_controller.dart';
import '../providers/document_provider.dart';
import '../providers/narration_provider.dart';

abstract final class NarrationActions {
  static Future<void> readSelection(WidgetRef ref) async {
    final document = ref.read(currentDocumentProvider);
    final viewer = ref.read(pdfViewerControllerProvider);
    if (document == null || !viewer.isReady) return;
    final selection = viewer.textSelectionDelegate;
    final narrator = ref.read(narrationControllerProvider);
    await narrator.read(document.session, () async {
      if (!selection.isCopyAllowed) {
        throw StateError('This PDF does not allow text extraction.');
      }
      if (!selection.hasSelectedText) {
        throw StateError('Select some text in the paper to read aloud.');
      }
      final text = await document.session.lease.use(
        (_) => selection.getSelectedText(),
      );
      if (document.session.lease.isClosed) {
        throw StateError('The document was closed.');
      }
      return NarrationSource(
        documentId: document.session,
        title: document.title,
        text: text,
      );
    });
  }
}
