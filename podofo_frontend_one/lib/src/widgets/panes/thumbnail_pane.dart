import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;
import 'package:podofo_one/src/providers/providers.dart';
import 'package:podofo_one/src/workers/thumbnail_worker.dart';

class ThumbnailPane extends ConsumerWidget {
  const ThumbnailPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filePath = ref.watch(filePathProvider);
    final theme = ref.watch(themeProvider);
    final bool darkMode = theme == ThemeMode.dark;
    final shader = ref.watch(shaderProvider);

    if (filePath == null) {
      return const Center(child: Text('No document loaded'));
    } else {
      final thumbnailsState = ref.watch(thumbnailsProvider);
      final thumbnails = thumbnailsState.thumbnails[filePath];
      final isGenerating = thumbnailsState.isGenerating[filePath] ?? false;

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
          final gridTile = GridTile(
            header: GridTileBar(title: Text('$pageNumber')),
            child: Image.memory(thumbnailBytes),
          );

          if (darkMode) {
            return shader.when(
              data: (fs) => ImageFiltered(
                imageFilter: ImageFilter.shader(fs),
                child: gridTile,
              ),
              loading: () => gridTile,
              error: (e, s) {
                return gridTile;
              },
            );
          } else {
            return gridTile;
          }
        },
      );
    }
  }
}
