import 'dart:ui';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart';

import 'package:file_picker/file_picker.dart';
import 'package:pdfrx/pdfrx.dart';

import 'package:podofo_one/src/data/document_data.dart';
import 'package:podofo_one/src/providers/tab_provider.dart';
import 'package:podofo_one/src/workers/thumbnail_worker.dart';

final leftPaneProvider = StateProvider<dynamic>((ref) => null);
final rightPaneProvider = StateProvider<dynamic>((ref) => null);

final commandPaletteProvider = StateProvider<bool>((ref) => false);

final themeProvider = StateProvider<ThemeMode>((ref) => ThemeMode.dark);

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

final loadedDocumentsProvider =
    NotifierProvider<LoadedDocumentsNotifier, Map<String, Document>>(
      LoadedDocumentsNotifier.new,
    );

class LoadedDocumentsNotifier extends Notifier<Map<String, Document>> {
  @override
  Map<String, Document> build() => {};

  void addDocument(String filePath) async {
    if (state.containsKey(filePath)) {
      return;
    }
    final pdfDocument = await PdfDocument.openFile(filePath);
    state = {
      ...state,
      filePath: Document(filePath: filePath, pdfDocument: pdfDocument),
    };
  }

  void removeDocument(String filePath) {
    state = Map.from(state)..remove(filePath);
  }
}

final currentDocumentProvider = Provider<PdfDocument?>((ref) {
  final tabs = ref.watch(tabsProvider);
  final currentTabIndex = ref.watch(currentTabIndexProvider);
  if (tabs.isEmpty || currentTabIndex >= tabs.length) {
    return null;
  }
  return tabs[currentTabIndex].pdfDocument;
});

final pdfViewerControllerProvider = StateProvider<PdfViewerController>(
  (ref) => PdfViewerController(),
);

final shaderProvider = FutureProvider<FragmentShader>((ref) async {
  final program = await FragmentProgram.fromAsset('shaders/invert.frag');
  return program.fragmentShader();
});

final thumbnailsProvider =
    StateNotifierProvider<ThumbnailsNotifier, ThumbnailsState>((ref) {
      final notifier = ThumbnailsNotifier();
      ref.listen(currentDocumentProvider, (_, doc) {
        if (doc != null) {
          notifier.generateThumbnails(doc);
        }
      });
      return notifier;
    });
