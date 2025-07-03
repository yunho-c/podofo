import 'dart:io' show Platform;
import 'dart:ui';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import 'package:file_picker/file_picker.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'package:podofo_one/main.dart';
import 'package:podofo_one/objectbox.g.dart';
import 'package:podofo_one/src/data/document_data.dart';
import 'package:podofo_one/src/data/document_entity.dart';
import 'package:podofo_one/src/data/pane_data.dart';
import 'package:podofo_one/src/providers/tab_provider.dart';
import 'package:podofo_one/src/providers/user_state_provider.dart';
import 'package:podofo_one/src/widgets/areas/sidebar.dart';
import 'package:podofo_one/src/workers/thumbnail_worker.dart';

final objectboxProvider = Provider((ref) => objectbox);

final leftPaneProvider = StateProvider<SideBarItem?>((ref) => null);
final rightPaneProvider = StateProvider<SideBarItem?>((ref) => null);

final commandPaletteProvider = StateProvider<bool>((ref) => false);

final themeModeProvider = StateProvider<ThemeMode>((ref) => ThemeMode.dark);

// HACK: This is copy-pasted from `main.dart` and does not properly implement
//       state reactivity.
Typography typography = const Typography.geist().copyWith(
  sans: const TextStyle(fontFamily: 'Urbanist'),
);

final themeDataProvider = Provider<ThemeData>((ref) {
  final themeMode = ref.watch(themeModeProvider);
  return switch (themeMode) {
    ThemeMode.light => ThemeData(
      typography: typography,
      colorScheme: ColorSchemes.lightZinc(),
      radius: 0.5,
    ),
    ThemeMode.dark => ThemeData(
      typography: typography,
      colorScheme: ColorSchemes.darkZinc(),
      radius: 0.5,
    ),
    _ => ThemeData(
      typography: typography,
      colorScheme: ColorSchemes.darkZinc(),
      radius: 0.5,
    ),
  };
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
    );
  }
  return loadedDocuments;
});

final loadedDocumentsProvider =
    NotifierProvider<LoadedDocumentsNotifier, Map<String, Document>>(
      LoadedDocumentsNotifier.new,
    );

class LoadedDocumentsNotifier extends Notifier<Map<String, Document>> {
  @override
  Map<String, Document> build() {
    return ref.watch(initialDocumentsProvider).asData?.value ?? {};
  }

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

final shaderProvider = NotifierProvider<ShaderNotifier, FragmentShader?>(
  ShaderNotifier.new,
);

class ShaderNotifier extends Notifier<FragmentShader?> {
  FragmentProgram? _program;

  @override
  FragmentShader? build() {
    _loadProgram();
    return null;
  }

  Future<void> _loadProgram() async {
    try {
      _program = await FragmentProgram.fromAsset('shaders/invert.frag');
      state = _program?.fragmentShader()?..setFloat(2, 1.0);
    } catch (e, s) {
      print('Failed to load shader: $e');
      print(s);
    }
  }

  void setUniform(double value) {
    if (_program != null) {
      state = _program!.fragmentShader()..setFloat(2, value);
    }
  }
}

final thumbnailsProvider =
    StateNotifierProvider<ThumbnailsNotifier, ThumbnailsState>((ref) {
      final objectbox = ref.watch(objectboxProvider);
      final notifier = ThumbnailsNotifier(objectbox);
      ref.listen(currentDocumentProvider, (_, doc) {
        if (doc != null) {
          notifier.generateThumbnails(doc.pdfDocument);
        }
      });
      return notifier;
    });

// TODO: Data-ify this, instead of hard-coding.
// TODO: Persistence (serialization), editor visualization, editing
// TODO: Real-time visualization for the entire app (toggleable via 'More')
final hotkeySetupProvider = Provider<void>((ref) {
  final Map<int, PhysicalKeyboardKey> topRowNumberKeys = {
    1: PhysicalKeyboardKey.digit1,
    2: PhysicalKeyboardKey.digit2,
    3: PhysicalKeyboardKey.digit3,
    4: PhysicalKeyboardKey.digit4,
    5: PhysicalKeyboardKey.digit5,
    6: PhysicalKeyboardKey.digit6,
    7: PhysicalKeyboardKey.digit7,
    8: PhysicalKeyboardKey.digit8,
    9: PhysicalKeyboardKey.digit9,
    0: PhysicalKeyboardKey.digit0,
  };

  hotKeyManager.register(
    HotKey(
      key: PhysicalKeyboardKey.keyP,
      modifiers: [HotKeyModifier.control],
      scope: HotKeyScope.inapp,
    ),
    keyDownHandler: (_) {
      ref.read(commandPaletteProvider.notifier).update((state) => !state);
    },
  );
  hotKeyManager.register(
    HotKey(
      key: PhysicalKeyboardKey.keyH,
      modifiers: [],
      scope: HotKeyScope.inapp,
    ),
    keyDownHandler: (_) {
      final currentHighlight = ref.read(userStateNotifierProvider).highlight;
      ref
          .read(userStateNotifierProvider.notifier)
          .setHighlight(!currentHighlight);
    },
  );
  hotKeyManager.register(
    HotKey(
      key: PhysicalKeyboardKey.keyB,
      modifiers: [
        Platform.isMacOS ? HotKeyModifier.meta : HotKeyModifier.control,
      ],
      scope: HotKeyScope.inapp,
    ),
    keyDownHandler: (_) {
      ref.read(leftPaneProvider.notifier).update((state) {
        return state == leftPaneData.items[0] ? null : leftPaneData.items[0];
      });
    },
  );
  hotKeyManager.register(
    HotKey(
      key: PhysicalKeyboardKey.keyO,
      modifiers: [
        Platform.isMacOS ? HotKeyModifier.meta : HotKeyModifier.control,
      ],
      scope: HotKeyScope.inapp,
    ),
    keyDownHandler: (_) {
      ref.read(leftPaneProvider.notifier).update((state) {
        return state == leftPaneData.items[1] ? null : leftPaneData.items[1];
      });
    },
  );
  hotKeyManager.register(
    HotKey(
      key: PhysicalKeyboardKey.keyF,
      modifiers: [
        Platform.isMacOS ? HotKeyModifier.meta : HotKeyModifier.control,
      ],
      scope: HotKeyScope.inapp,
    ),
    keyDownHandler: (_) {
      ref.read(leftPaneProvider.notifier).update((state) {
        return state == leftPaneData.items[3] ? null : leftPaneData.items[3];
      });
    },
  );
  hotKeyManager.register(
    HotKey(
      key: PhysicalKeyboardKey.keyF,
      modifiers: [
        Platform.isMacOS ? HotKeyModifier.meta : HotKeyModifier.control,
        HotKeyModifier.shift,
      ],
      scope: HotKeyScope.inapp,
    ),
    keyDownHandler: (_) {
      ref.read(leftPaneProvider.notifier).update((state) {
        return state == leftPaneData.items[4] ? null : leftPaneData.items[4];
      });
    },
  );
  hotKeyManager.register(
    HotKey(
      key: PhysicalKeyboardKey.tab,
      modifiers: [HotKeyModifier.control],
      scope: HotKeyScope.inapp,
    ),
    keyDownHandler: (_) {
      final notifier = ref.read(currentTabIndexProvider.notifier);
      final loadedDocuments = ref.read(loadedDocumentsProvider);
      if (loadedDocuments.length > 1) {
        notifier.state = (notifier.state + 1) % loadedDocuments.length;
      }
    },
  );
  hotKeyManager.register(
    HotKey(
      key: PhysicalKeyboardKey.tab,
      modifiers: [HotKeyModifier.control, HotKeyModifier.shift],
      scope: HotKeyScope.inapp,
    ),
    keyDownHandler: (_) {
      final notifier = ref.read(currentTabIndexProvider.notifier);
      final loadedDocuments = ref.read(loadedDocumentsProvider);
      if (loadedDocuments.length > 1) {
        notifier.state =
            (notifier.state - 1 + loadedDocuments.length) %
            loadedDocuments.length;
      }
    },
  );

  topRowNumberKeys.forEach((number, key) {
    hotKeyManager.register(
      HotKey(
        key: key,
        modifiers: [
          Platform.isMacOS ? HotKeyModifier.meta : HotKeyModifier.control,
        ],
        scope: HotKeyScope.inapp,
      ),
      keyDownHandler: (_) {
        final loadedDocuments = ref.read(loadedDocumentsProvider);
        if (number <= loadedDocuments.length) {
          ref.read(currentTabIndexProvider.notifier).state = number - 1;
        }
      },
    );
  });

  hotKeyManager.register(
    HotKey(
      key: PhysicalKeyboardKey.digit0,
      modifiers: [
        Platform.isMacOS ? HotKeyModifier.meta : HotKeyModifier.control,
      ],
      scope: HotKeyScope.inapp,
    ),
    keyDownHandler: (_) {
      final loadedDocuments = ref.read(loadedDocumentsProvider);
      if (loadedDocuments.isNotEmpty) {
        ref.read(currentTabIndexProvider.notifier).state =
            loadedDocuments.length - 1;
      }
    },
  );

  hotKeyManager.register(
    HotKey(
      key: PhysicalKeyboardKey.keyW,
      modifiers: [
        Platform.isMacOS ? HotKeyModifier.meta : HotKeyModifier.control,
      ],
      scope: HotKeyScope.inapp,
    ),
    keyDownHandler: (_) {
      final loadedDocuments = ref.read(loadedDocumentsProvider);
      final currentDocument = ref.read(currentDocumentProvider);
      if (currentDocument != null) {
        ref
            .read(loadedDocumentsProvider.notifier)
            .removeDocument(currentDocument.filePath);
      }
    },
  );
});
