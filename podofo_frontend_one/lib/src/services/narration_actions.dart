import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfrx/pdfrx.dart';

import '../narration/narration_controller.dart';
import '../narration/source_map.dart';
import '../providers/document_provider.dart';
import '../providers/narration_provider.dart';
import '../providers/tab_provider.dart';

abstract final class NarrationActions {
  static void showSource(WidgetRef ref) {
    final source = ref.read(narrationControllerProvider).source;
    final documents = ref.read(loadedDocumentsProvider).values.toList();
    final index = documents.indexWhere(
      (d) => identical(d.session, source?.documentId),
    );
    if (index >= 0) ref.read(currentTabIndexProvider.notifier).state = index;
    ref.read(narrationControllerProvider).setFollowText(true);
  }

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
      final passage = await document.session.readLocked((_) async {
        final ranges = await selection.getSelectedTextRanges();
        return NarrationPassage.fromSlices([
          for (final range in ranges)
            PdfTextSlice(
              PdfTextSnapshot.fromText(range.pageText),
              range.start,
              range.end,
            ),
        ]);
      });
      if (document.session.lease.isClosed) {
        throw StateError('The document was closed.');
      }
      return NarrationSource(
        documentId: document.session,
        title: document.title,
        text: passage.text,
        passage: passage,
      );
    });
  }

  static Future<void> readFromHere(WidgetRef ref) async {
    final document = ref.read(currentDocumentProvider);
    final viewer = ref.read(pdfViewerControllerProvider);
    if (document == null || !viewer.isReady) return;
    final selection = viewer.textSelectionDelegate;
    final page = viewer.pageNumber ?? 1;
    await ref.read(narrationControllerProvider).read(
      document.session,
      () async {
        final passage = await document.session.readLocked((pdf) async {
          if (pdf.permissions?.allowsCopying == false) {
            throw StateError('This PDF does not allow text extraction.');
          }
          final ranges = selection.hasSelectedText
              ? await selection.getSelectedTextRanges()
              : null;
          final selected = ranges?.firstOrNull;
          final number = selected?.pageNumber ?? page;
          final snapshot = PdfTextSnapshot.fromText(
            await NarrationPdfPage(pdf.pages[number - 1]).loadStructuredText(),
          );
          if (selected != null && selected.pageText.fullText != snapshot.text) {
            throw StateError(
              'The selected text positions changed. Clear the selection and read this page again.',
            );
          }
          return NarrationPassage.fromSlices([
            PdfTextSlice(snapshot, selected?.start ?? 0, snapshot.text.length),
          ]);
        });
        return NarrationSource(
          documentId: document.session,
          title: document.title,
          text: passage.text,
          passage: passage,
        );
      },
    );
  }
}
