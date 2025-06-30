import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';
import 'dart:ui';

enum LeftPane { explorer, search, sourceControl, debug, extensions }

enum RightPane { outline, timeline }

final leftPaneProvider = StateProvider<LeftPane?>((ref) => LeftPane.explorer);
final rightPaneProvider = StateProvider<RightPane?>((ref) => null);

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
    }
  }
}

final pdfViewerControllerProvider = StateProvider<PdfViewerController>(
  (ref) => PdfViewerController(),
);

final shaderProvider = FutureProvider<FragmentShader>((ref) async {
  final program = await FragmentProgram.fromAsset('shaders/invert.frag');
  return program.fragmentShader();
});
