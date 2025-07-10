import 'dart:ui';
import 'package:flutter/material.dart' show Scaffold;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' hide Scaffold;

import 'package:podofo_one/src/providers/providers.dart';
import 'package:podofo_one/src/widgets/components/thumbnail_card.dart';

class ThumbnailPane extends ConsumerWidget {
  const ThumbnailPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentDoc = ref.watch(currentDocumentProvider);
    final brightness = ref.watch(brightnessProvider);
    final bool darkMode = brightness == Brightness.dark;
    final shader = ref.watch(shaderProvider);

    if (currentDoc == null) {
      return const Center(child: Text('No document loaded'));
    } else {
      final currentPageNumber = currentDoc.lastOpenedPage ?? 0;
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

      return Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(8.0),
          child: GridView.builder(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 1,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
              childAspectRatio: 1 / 1.38,
            ),
            itemCount: thumbnails.length,
            itemBuilder: (BuildContext context, int index) {
              final pageNumber = thumbnails.keys.elementAt(index);
              final thumbnailBytes = thumbnails.values.elementAt(index);

              Widget imageWidget = Image.memory(thumbnailBytes);

              if (darkMode && shader != null) {
                imageWidget = ImageFiltered(
                  imageFilter: ImageFilter.shader(shader),
                  child: imageWidget,
                );
              }
              return ThumbnailCard(
                active: pageNumber == currentPageNumber,
                thumbnail: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: imageWidget,
                ),
                label: '${pageNumber + 1}',
                onPressed: () {
                  print('Tapped on Page ${pageNumber + 1}');
                },
              );
            },
          ),
        ),
      );
    }
  }
}
