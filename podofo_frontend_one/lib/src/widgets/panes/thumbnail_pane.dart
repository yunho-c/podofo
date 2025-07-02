import 'dart:ui';
import 'package:flutter/material.dart' hide ThemeMode;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart'
    hide CircularProgressIndicator;

import 'package:podofo_one/src/providers/providers.dart';

class ThumbnailPane extends ConsumerWidget {
  const ThumbnailPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentDoc = ref.watch(currentDocumentProvider);
    final theme = ref.watch(themeModeProvider);
    final bool darkMode = theme == ThemeMode.dark;
    final shader = ref.watch(shaderProvider);

    if (currentDoc == null) {
      return const Center(child: Text('No document loaded'));
    } else {
      final thumbnailsState = ref.watch(thumbnailsProvider);
      final thumbnails = thumbnailsState.thumbnails[currentDoc.filePath];
      final isGenerating =
          thumbnailsState.isGenerating[currentDoc.filePath] ?? false;

      if (isGenerating) {
        return const Center(child: CircularProgressIndicator());
      }

      if (thumbnails == null || thumbnails.isEmpty) {
        return const Center(child: Text('No thumbnails available.'));
      }

      return GridView.builder(
        shrinkWrap: true,
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 1,
          crossAxisSpacing: 4.0,
          mainAxisSpacing: 4.0,
        ),
        itemCount: thumbnails.length,
        itemBuilder: (context, index) {
          final pageNumber = thumbnails.keys.elementAt(index);
          final thumbnailBytes = thumbnails.values.elementAt(index);

          Widget imageWidget = Image.memory(thumbnailBytes);

          if (darkMode && shader != null) {
            imageWidget = ImageFiltered(
              imageFilter: ImageFilter.shader(shader),
              child: imageWidget,
            );
          }

          return GridTile(
            header: GridTileBar(title: Text('$pageNumber')),
            child: imageWidget,
          );
        },
      );
    }
  }
}
