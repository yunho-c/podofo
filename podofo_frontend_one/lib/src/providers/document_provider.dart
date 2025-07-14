import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfrx/pdfrx.dart';

import 'package:podofo_one/objectbox.g.dart';
import 'package:podofo_one/src/data/document_data.dart';
import 'package:podofo_one/src/data/document_entity.dart';
import 'package:podofo_one/src/providers/data_provider.dart';
import 'package:podofo_one/src/providers/tab_provider.dart';
import 'package:podofo_one/src/workers/thumbnail_worker.dart';
import 'package:podofo_one/src/data/document_history_entity.dart';

final documentHistoryProvider =
    FutureProvider<List<DocumentHistoryEntity>>((ref) async {
  final box = ref.read(objectboxProvider).store.box<DocumentHistoryEntity>();
  final query = box
      .query()
      .order(DocumentHistoryEntity_.lastOpened, flags: Order.descending)
      .build();
  final history = query.find();
  query.close();
  return history;
});

final filePathProvider = NotifierProvider<FilePathNotifier, String?>(
  FilePathNotifier.new,
);

class FilePathNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void pickFile({List<String> exts = const ['pdf']}) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: exts,
    );

    if (result != null && result.files.single.path != null) {
      state = result.files.single.path;
      ref.read(loadedDocumentsProvider.notifier).addDocument(state!);
    }
  }
}

final initialDocumentsProvider = FutureProvider<Map<String, Document>>((
  ref,
) async {
  final box = ref.read(objectboxProvider).store.box<DocumentEntity>();
  final documents = box.getAll();
  final Map<String, Document> loadedDocuments = {};

  for (final doc in documents) {
    final pdfDocument = await PdfDocument.openFile(doc.filePath);
    loadedDocuments[doc.filePath] = Document(
      filePath: doc.filePath,
      pdfDocument: pdfDocument,
      lastOpenedPage: doc.lastOpenedPage,
    );
  }
  return loadedDocuments;
});

final loadedDocumentsProvider =
    NotifierProvider<LoadedDocumentsNotifier, Map<String, Document>>(
      LoadedDocumentsNotifier.new,
    );

/// Manages the state of loaded documents, acting as a bridge between the
/// persistent storage (cold state) and the in-memory representation (hot state).
///
/// This notifier is responsible for:
///   - Loading the initial set of documents from ObjectBox (`initialDocumentsProvider`).
///   - Providing the fully loaded `Document` objects to the UI for fast access.
///   - Synchronizing any changes (additions/removals) back to ObjectBox to
///     ensure persistence across sessions.
///
/// This "hot/cold" state pattern is used to optimize performance. The "hot"
/// state (in-memory `Map<String, Document>`) provides immediate access to
/// fully-hydrated `Document` objects, which is crucial for a responsive UI.
/// The "cold" state (ObjectBox `DocumentEntity`) ensures that the list of
/// documents is not lost when the app is closed.
class LoadedDocumentsNotifier extends Notifier<Map<String, Document>> {
  @override
  Map<String, Document> build() {
    return ref.watch(initialDocumentsProvider).asData?.value ?? {};
  }

  void _updateHistory(String filePath) {
    final historyBox =
        ref.read(objectboxProvider).store.box<DocumentHistoryEntity>();
    historyBox.put(DocumentHistoryEntity(
      filePath: filePath,
      lastOpened: DateTime.now(),
    ));
    ref.invalidate(documentHistoryProvider);
  }

  void addDocument(String filePath) async {
    if (state.containsKey(filePath)) {
      ref.read(currentTabIndexProvider.notifier).state =
          state.keys.toList().indexOf(filePath);
      _updateHistory(filePath);
      return;
    }
    final pdfDocument = await PdfDocument.openFile(filePath);
    state = {
      ...state,
      filePath: Document(filePath: filePath, pdfDocument: pdfDocument),
    };

    // Add to objectbox
    final box = ref.read(objectboxProvider).store.box<DocumentEntity>();
    box.put(DocumentEntity(filePath: filePath));
    _updateHistory(filePath);
  }

  void removeDocument(String filePath) {
    state = Map.from(state)..remove(filePath);

    // Remove from objectbox
    final box = ref.read(objectboxProvider).store.box<DocumentEntity>();
    final query = box.query(DocumentEntity_.filePath.equals(filePath)).build();
    final result = query.findFirst();
    if (result != null) {
      box.remove(result.id);
    }
    query.close();
  }

  void updateDocumentPage(String filePath, int pageNumber) {
    if (!state.containsKey(filePath)) return;

    // Update in-memory state
    final newState = Map<String, Document>.from(state);
    newState[filePath] = newState[filePath]!.copyWith(
      lastOpenedPage: pageNumber,
    );
    state = newState;

    // Update objectbox
    final box = ref.read(objectboxProvider).store.box<DocumentEntity>();
    final query = box.query(DocumentEntity_.filePath.equals(filePath)).build();
    final result = query.findFirst();
    if (result != null) {
      result.lastOpenedPage = pageNumber;
      box.put(result);
    }
    query.close();
  }
}

final currentDocumentProvider = Provider<Document?>((ref) {
  final loadedDocuments = ref.watch(loadedDocumentsProvider);
  final currentTabIndex = ref.watch(currentTabIndexProvider);
  if (loadedDocuments.isEmpty || currentTabIndex >= loadedDocuments.length) {
    return null;
  }
  return loadedDocuments.values.toList()[currentTabIndex];
});

final outlineProvider = FutureProvider<List<PdfOutlineNode>>((ref) async {
  final document = ref.watch(currentDocumentProvider);
  if (document == null) {
    return [];
  }
  return await document.pdfDocument.loadOutline();
});

final pdfViewerControllerProvider = StateProvider<PdfViewerController>(
  (ref) => PdfViewerController(),
);

final thumbnailsProvider =
    StateNotifierProvider<ThumbnailsNotifier, ThumbnailsState>((ref) {
      final objectbox = ref.watch(objectboxProvider);
      final notifier = ThumbnailsNotifier(objectbox);
      ref.listen(currentDocumentProvider, (_, doc) {
        if (doc != null) {
          notifier.retrieveThumbnails(doc.pdfDocument);
        }
      });
      return notifier;
    });

final pdfTextSearcherProvider = Provider<PdfTextSearcher>((ref) {
  final pdfViewerController = ref.watch(pdfViewerControllerProvider);
  final searcher = PdfTextSearcher(pdfViewerController);
  ref.onDispose(searcher.dispose);
  return searcher;
});
