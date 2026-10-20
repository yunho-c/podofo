import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart' as m;
import 'package:pdfrx/pdfrx.dart';

import '../narration/narration_controller.dart';
import '../narration/source_map.dart';
import '../providers/document_provider.dart';
import '../providers/narration_provider.dart';
import '../providers/tab_provider.dart';
import '../narration/paper_plan.dart';
import '../narration/paper_sequence.dart';
import '../widgets/components/paper_reading_preview.dart';

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
    try {
      final anchor = await document.session.readLocked((pdf) async {
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
        return snapshot.anchor(selected?.start ?? 0);
      });
      if (ref.context.mounted) await readPaper(ref, anchor: anchor);
    } catch (failure) {
      if (ref.context.mounted) {
        await ref
            .read(narrationControllerProvider)
            .read(document.session, () async => throw failure);
      }
    }
  }

  static Future<void> readPaper(
    WidgetRef ref, {
    int? page,
    bool resume = false,
    SourceAnchor? anchor,
    PaperReadOptions options = const PaperReadOptions(),
  }) async {
    final document = ref.read(currentDocumentProvider);
    if (document == null) return;
    final controller = ref.read(narrationControllerProvider);
    final saved = resume
        ? ref.read(narrationBookmarksProvider).find(document.filePath)
        : null;
    if (saved != null && saved.mappingVersion == 1) anchor = saved.anchor;
    final viewer = ref.read(pdfViewerControllerProvider);
    final start =
        (anchor?.page ??
                page ??
                (viewer.isReady ? viewer.pageNumber : null) ??
                1)
            .clamp(1, document.pdfDocument.pages.length);
    final sequence = PaperSequence(document.session, options);
    final choice = await m.showDialog<PaperReadingChoice>(
      context: ref.context,
      builder: (_) =>
          PaperReadingPreview(sequence: sequence, page: start, anchor: anchor),
    );
    if (!ref.context.mounted ||
        choice == null ||
        document.session.lease.isClosed) {
      sequence.close();
      return;
    }
    sequence.options = choice.options;
    await controller.read(document.session, () async {
      try {
        final passage = await sequence.start(
          page: choice.page,
          anchor: choice.anchor,
        );
        if (passage == null) {
          throw StateError('There is no readable text after this position.');
        }
        return NarrationSource(
          documentId: document.session,
          title: document.title,
          text: passage.text,
          passage: passage,
          sequence: sequence,
        );
      } catch (_) {
        sequence.close();
        rethrow;
      }
    });
  }
}
