import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart' as m;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/document_data.dart';
import '../providers/document_provider.dart';
import '../providers/user_state_provider.dart';
import 'pdf_highlights.dart';
import 'pdf_session.dart';

class DocumentActions {
  static final _highlighting = Expando<bool>();

  static void error(WidgetRef ref, Object error) {
    ref.read(documentErrorProvider.notifier).state = error.toString();
  }

  static Future<bool> save(
    m.BuildContext context,
    WidgetRef ref,
    Document document, {
    bool saveAs = false,
  }) async {
    try {
      String? destination, expected;
      if (saveAs) {
        final location = await getSaveLocation(
          suggestedName: document.title,
          acceptedTypeGroups: const [
            XTypeGroup(
              label: 'PDF documents',
              extensions: ['pdf'],
              uniformTypeIdentifiers: ['com.adobe.pdf'],
            ),
          ],
        );
        destination = location?.path;
        if (destination == null || !context.mounted) return false;
        if (!destination.toLowerCase().endsWith('.pdf')) destination += '.pdf';
        expected = await AtomicPdfFile.fingerprint(destination);
        if (expected != null) {
          if (!context.mounted) return false;
          final replace = await m.showDialog<bool>(
            context: context,
            builder: (context) => m.AlertDialog(
              title: const m.Text('Replace this PDF?'),
              content: m.Text(destination!),
              actions: [
                m.TextButton(
                  onPressed: () => m.Navigator.pop(context, false),
                  child: const m.Text('Cancel'),
                ),
                m.FilledButton(
                  onPressed: () => m.Navigator.pop(context, true),
                  child: const m.Text('Replace'),
                ),
              ],
            ),
          );
          if (replace != true) return false;
        }
      }
      await ref
          .read(loadedDocumentsProvider.notifier)
          .saveDocument(
            document,
            destination: destination,
            expectedTarget: expected,
          );
      return true;
    } catch (e) {
      if (context.mounted) error(ref, e);
      return false;
    }
  }

  /// null = cancelled, false = clean/saved, true = explicitly discard.
  static Future<bool?> resolveUnsaved(
    m.BuildContext context,
    WidgetRef ref,
    Document document,
  ) async {
    if (!document.dirty) return false;
    final choice = await m.showDialog<String>(
      context: context,
      builder: (context) => m.AlertDialog(
        title: m.Text('Save changes to ${document.title}?'),
        content: const m.Text('This PDF contains unsaved highlights.'),
        actions: [
          m.TextButton(
            onPressed: () => m.Navigator.pop(context, 'cancel'),
            child: const m.Text('Cancel'),
          ),
          m.TextButton(
            onPressed: () => m.Navigator.pop(context, 'discard'),
            child: const m.Text('Discard'),
          ),
          m.FilledButton(
            onPressed: () => m.Navigator.pop(context, 'save'),
            child: const m.Text('Save'),
          ),
        ],
      ),
    );
    if (choice == 'discard') return true;
    if (choice != 'save' || !context.mounted) return null;
    return await save(context, ref, document) ? false : null;
  }

  static Future<void> close(
    m.BuildContext context,
    WidgetRef ref,
    Document document,
  ) async {
    final discard = await resolveUnsaved(context, ref, document);
    if (discard == null || !context.mounted) return;
    try {
      await ref
          .read(loadedDocumentsProvider.notifier)
          .removeDocument(document.filePath, discard: discard);
    } catch (e) {
      if (context.mounted) error(ref, e);
    }
  }

  static Future<void> highlight(WidgetRef ref, {String? color}) async {
    final document = ref.read(currentDocumentProvider);
    final controller = ref.read(pdfViewerControllerProvider);
    if (document == null || !controller.isReady) return;
    final selection = controller.textSelectionDelegate;
    if (!selection.hasSelectedText) return;
    if (_highlighting[selection] == true) return;
    _highlighting[selection] = true;
    final selectedColor =
        color ??
        ref.read(userStateNotifierProvider).highlightColor ??
        '#66ffeb3b';
    try {
      final ranges = await selection.getSelectedTextRanges();
      if (!ref.context.mounted ||
          ref.read(currentDocumentProvider)?.session != document.session ||
          document.session.lease.isClosed) {
        return;
      }
      final regions = HighlightRegion.fromTextRanges(
        ranges,
        includeText: selection.isCopyAllowed,
      );
      if (regions.isEmpty) return;
      await selection.clearTextSelection();
      await ref
          .read(loadedDocumentsProvider.notifier)
          .highlight(
            document,
            regions,
            int.parse(selectedColor.replaceFirst('#', ''), radix: 16),
          );
    } catch (e) {
      if (ref.context.mounted) error(ref, e);
    } finally {
      _highlighting[selection] = false;
    }
  }
}
