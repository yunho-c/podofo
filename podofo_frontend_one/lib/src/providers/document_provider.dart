import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:path/path.dart' as p;
import 'package:synchronized/synchronized.dart';

import '../../objectbox.g.dart';
import '../data/document_data.dart';
import '../data/document_entity.dart';
import '../data/document_history_entity.dart';
import '../services/pdf_session.dart';
import '../services/pdf_highlights.dart';
import 'data_provider.dart';
import 'narration_provider.dart';
import 'tab_provider.dart';
import 'user_state_provider.dart';

final documentHistoryProvider = FutureProvider<List<DocumentHistoryEntity>>((
  ref,
) async {
  final box = ref.read(objectboxProvider).store.box<DocumentHistoryEntity>();
  final query = box
      .query()
      .order(DocumentHistoryEntity_.lastOpened, flags: Order.descending)
      .build();
  try {
    return query.find();
  } finally {
    query.close();
  }
});

final documentFailuresProvider = StateProvider<Map<String, String>>(
  (ref) => {},
);
final documentErrorProvider = StateProvider<String?>((ref) => null);
final filePathProvider = NotifierProvider<FilePathNotifier, String?>(
  FilePathNotifier.new,
);

class FilePathNotifier extends Notifier<String?> {
  @override
  String? build() => null;
  Future<void> pickFile({List<String> exts = const ['pdf']}) async {
    try {
      final result = await openFile(
        acceptedTypeGroups: [
          XTypeGroup(
            label: 'PDF documents',
            extensions: exts,
            uniformTypeIdentifiers: const ['com.adobe.pdf'],
          ),
        ],
      );
      if (!ref.mounted || result == null) return;
      state = result.path;
      await ref.read(loadedDocumentsProvider.notifier).addDocument(state!);
    } catch (e) {
      if (ref.mounted) {
        ref.read(documentErrorProvider.notifier).state =
            'Could not open file: $e';
      }
    }
  }
}

final initialDocumentsProvider = FutureProvider<Map<String, Document>>((
  ref,
) async {
  // Defer mutations until provider construction has completed.
  await Future<void>.value();
  final notifier = ref.read(loadedDocumentsProvider.notifier);
  await notifier.restore();
  return ref.read(loadedDocumentsProvider);
});

final loadedDocumentsProvider =
    NotifierProvider<LoadedDocumentsNotifier, Map<String, Document>>(
      LoadedDocumentsNotifier.new,
    );

class LoadedDocumentsNotifier extends Notifier<Map<String, Document>> {
  final _operations = Lock();
  final _owned = <PdfSession>{};
  @override
  Map<String, Document> build() {
    ref.onDispose(() {
      for (final session in _owned) {
        session.lease.close();
      }
      _owned.clear();
    });
    return {};
  }

  Box<DocumentEntity> get _box =>
      ref.read(objectboxProvider).store.box<DocumentEntity>();

  Future<void> restore() async {
    final records = _box.getAll();
    for (final record in records) {
      if (!ref.mounted) return;
      await addDocument(
        record.filePath,
        lastPage: record.lastOpenedPage,
        activate: false,
      );
    }
  }

  void _failure(String path, Object error) {
    if (!ref.mounted) return;
    ref.read(documentFailuresProvider.notifier).state = {
      ...ref.read(documentFailuresProvider),
      path: error.toString(),
    };
  }

  Future<bool> addDocument(
    String filePath, {
    int? lastPage,
    bool activate = true,
  }) => _operations.synchronized(() async {
    final path = p.normalize(p.absolute(filePath));
    PdfSession? opened;
    try {
      // Compare canonical paths after opening too (symlinks and case).
      var key = state.keys.where((s) => p.equals(s, path)).firstOrNull;
      if (key == null) {
        opened = await PdfSession.open(path);
        if (!ref.mounted) {
          await opened.close();
          return false;
        }
        key = state.keys.where((s) => p.equals(s, opened!.path)).firstOrNull;
        if (key != null) {
          await opened.close();
          opened = null;
        }
      }
      if (key == null) {
        final session = opened!;
        key = session.path;
        final page = (lastPage ?? 1).clamp(
          1,
          session.lease.document.pages.length,
        );
        ref.read(objectboxProvider).store.runInTransaction(TxMode.write, () {
          _removeRecords(path);
          if (path != key) _removeRecords(key!);
          _box.put(DocumentEntity(filePath: key!, lastOpenedPage: page));
        });
        _owned.add(session);
        state = {
          ...state,
          key: Document(session: session, lastOpenedPage: page),
        };
        opened = null; // ownership transferred
      }
      if (path != key) _removeRecords(path);
      if (activate) {
        ref.read(currentTabIndexProvider.notifier).state = state.keys
            .toList()
            .indexOf(key);
      }
      final failures =
          Map<String, String>.from(ref.read(documentFailuresProvider))
            ..remove(filePath)
            ..remove(path);
      ref.read(documentFailuresProvider.notifier).state = failures;
      if (activate) {
        ref
            .read(objectboxProvider)
            .store
            .box<DocumentHistoryEntity>()
            .put(
              DocumentHistoryEntity(filePath: key, lastOpened: DateTime.now()),
            );
        ref.invalidate(documentHistoryProvider);
      }
      return true;
    } catch (e) {
      if (opened != null) await opened.close(discard: true);
      _failure(filePath, e);
      return false;
    }
  });

  DocumentEntity? _findRecord(String path) {
    final query = _box.query(DocumentEntity_.filePath.equals(path)).build();
    try {
      return query.findFirst();
    } finally {
      query.close();
    }
  }

  void forgetUnavailable(String path) {
    _removeRecords(path);
    ref.read(documentFailuresProvider.notifier).state =
        Map<String, String>.from(ref.read(documentFailuresProvider))
          ..remove(path);
  }

  Future<void> removeDocument(String path, {bool discard = false}) =>
      _operations.synchronized(() async {
        final document = state[path];
        if (document == null) return;
        await document.session.waitForIdle();
        // Do not stop narration for a rejected dirty close.
        if (document.dirty && !discard) {
          throw StateError('Save or discard changes before closing.');
        }
        await ref
            .read(narrationControllerProvider)
            .closeDocument(document.session);
        await document.session.close(discard: discard);
        final oldIndex = ref.read(currentTabIndexProvider);
        final removedIndex = state.keys.toList().indexOf(path);
        state = Map<String, Document>.from(state)..remove(path);
        _owned.remove(document.session);
        ref
            .read(currentTabIndexProvider.notifier)
            .state = (oldIndex - (removedIndex < oldIndex ? 1 : 0)).clamp(
          0,
          state.isEmpty ? 0 : state.length - 1,
        );
        _removeRecords(path);
      });

  Future<void> saveDocument(
    Document document, {
    String? destination,
    String? expectedTarget,
  }) => _operations.synchronized(() async {
    if (destination != null) {
      destination = p.normalize(p.absolute(destination!));
      if (await File(destination!).exists()) {
        destination = await File(destination!).resolveSymbolicLinks();
      }
    }
    if (destination != null &&
        state.values.any(
          (other) =>
              other.session != document.session &&
              p.equals(other.filePath, destination!),
        )) {
      throw StateError('That file is already open in another tab.');
    }
    final oldPath = document.filePath;
    await document.session.save(
      destination: destination,
      expectedTarget: expectedTarget,
    );
    if (!ref.mounted) return;
    if (oldPath != document.filePath) {
      // Preserve tab order when saving to a new path.
      state = {
        for (final entry in state.entries)
          entry.key == oldPath ? document.filePath : entry.key: entry.value,
      };
      try {
        ref.read(narrationBookmarksProvider).copy(oldPath, document.filePath);
        ref.read(objectboxProvider).store.runInTransaction(TxMode.write, () {
          _removeRecords(oldPath);
          _removeRecords(document.filePath);
          _box.put(
            DocumentEntity(
              filePath: document.filePath,
              lastOpenedPage: document.lastOpenedPage,
            ),
          );
        });
      } catch (e) {
        ref.read(documentErrorProvider.notifier).state =
            'PDF saved, but its session entry could not be updated: $e';
      }
    }
    refresh();
  });

  void _removeRecords(String path) {
    final query = _box.query(DocumentEntity_.filePath.equals(path)).build();
    try {
      _box.removeMany(query.findIds());
    } finally {
      query.close();
    }
  }

  Future<void> highlight(
    Document document,
    List<HighlightRegion> regions,
    int color,
  ) async {
    try {
      await document.session.highlight(regions, color);
    } finally {
      refresh();
    }
    await _autoSave(document);
  }

  Future<void> undoHighlight(Document document) async {
    try {
      await document.session.undoHighlight();
    } finally {
      refresh();
    }
    await _autoSave(document);
  }

  Future<void> removeHighlight(
    Document document,
    SavedHighlight highlight,
    int expectedRevision,
  ) async {
    try {
      await document.session.removeHighlight(highlight, expectedRevision);
    } finally {
      refresh();
    }
    await _autoSave(document);
  }

  Future<void> _autoSave(Document document) async {
    if (!ref.mounted ||
        document.session.lease.isClosed ||
        !ref.read(userStateNotifierProvider).autoSaveEnabled) {
      return;
    }
    try {
      await saveDocument(document);
    } catch (e) {
      ref.read(documentErrorProvider.notifier).state =
          'Auto-save failed. Your edits are still unsaved: $e';
    }
  }

  void refresh() {
    if (ref.mounted) {
      state = {
        for (final entry in state.entries) entry.key: entry.value.copyWith(),
      };
    }
  }

  void setTwoPageView(String path, bool enabled) {
    final document = state[path];
    if (document == null || document.twoPageView == enabled) return;
    state = {...state, path: document.copyWith(twoPageView: enabled)};
  }

  void updateDocumentPage(String path, int pageNumber) {
    if (!state.containsKey(path)) return;
    state = {...state, path: state[path]!.copyWith(lastOpenedPage: pageNumber)};
    try {
      final record = _findRecord(path);
      if (record != null) {
        record.lastOpenedPage = pageNumber;
        _box.put(record);
      }
    } catch (e) {
      ref.read(documentErrorProvider.notifier).state =
          'Could not remember page: $e';
    }
  }
}

final currentDocumentProvider = Provider<Document?>((ref) {
  final documents = ref.watch(loadedDocumentsProvider);
  final index = ref.watch(currentTabIndexProvider);
  if (documents.isEmpty || index < 0 || index >= documents.length) return null;
  return documents.values.elementAt(index);
});
final outlineProvider = FutureProvider<List<PdfOutlineNode>>((ref) async {
  final lease = ref.watch(
    currentDocumentProvider.select((doc) => doc?.session.lease),
  );
  return lease == null ? [] : lease.use((pdf) => pdf.loadOutline());
});
final pdfViewerControllerProvider = Provider<PdfViewerController>((ref) {
  ref.watch(currentDocumentProvider.select((doc) => doc?.session.lease));
  return PdfViewerController();
});
final viewerReadyProvider = StateProvider<PdfViewerController?>((ref) => null);
final pdfTextSearcherProvider = Provider<PdfTextSearcher?>((ref) {
  final controller = ref.watch(pdfViewerControllerProvider);
  if (ref.watch(viewerReadyProvider) != controller || !controller.isReady) {
    return null;
  }
  final searcher = PdfTextSearcher(controller);
  ref.onDispose(searcher.dispose);
  return searcher;
});
