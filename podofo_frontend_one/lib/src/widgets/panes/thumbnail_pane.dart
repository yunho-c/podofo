import 'dart:ui';

import 'package:flutter/material.dart' show Scaffold;
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' hide Scaffold;

import '../../providers/document_provider.dart';
import '../../providers/theme_provider.dart';
import '../../workers/thumbnail_worker.dart';
import '../components/thumbnail_card.dart';

class ThumbnailPane extends ConsumerWidget {
  const ThumbnailPane({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final document = ref.watch(currentDocumentProvider);
    if (document == null) {
      return const Center(child: Text('No document loaded'));
    }
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(8),
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth <= 0) return const SizedBox.shrink();
            final pages = document.pdfDocument.pages;
            double tileHeight(int index) =>
                constraints.maxWidth * pages[index].height / pages[index].width;
            // Bucket raster sizes to avoid rerendering for every resize pixel.
            final pixelWidth =
                ((constraints.maxWidth * pixelRatio / 64).ceil() * 64).clamp(
                  64,
                  1024,
                );
            ThumbnailRequest request(int index) => (
              session: document.session,
              revision: document.session.revision,
              page: index + 1,
              pixelWidth: pixelWidth,
              pixelHeight: ((tileHeight(index) * pixelRatio / 64).ceil() * 64)
                  .clamp(64, 1536),
            );
            var initialCount = 0;
            var initialHeight = 0.0;
            while (initialCount < pages.length &&
                initialHeight < constraints.maxHeight) {
              initialHeight += tileHeight(initialCount) + 8;
              initialCount++;
            }
            return Consumer(
              builder: (context, ref, _) {
                var loading = false;
                // The initial viewport shares one indicator; other pages stay lazy.
                for (var index = 0; index < initialCount; index++) {
                  loading =
                      ref.watch(thumbnailProvider(request(index))).isLoading ||
                      loading;
                }
                final thumbnails = FocusTraversalGroup(
                  child: ListView.separated(
                    key: ObjectKey(document.session),
                    scrollCacheExtent: const ScrollCacheExtent.pixels(300),
                    itemCount: pages.length,
                    separatorBuilder: (context, index) =>
                        const SizedBox(height: 8),
                    itemBuilder: (context, index) => SizedBox(
                      height: tileHeight(index),
                      child: _ThumbnailTile(
                        key: ValueKey('thumbnail-${index + 1}'),
                        request: request(index),
                      ),
                    ),
                  ),
                );
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    IgnorePointer(
                      ignoring: loading,
                      child: ExcludeFocus(
                        excluding: loading,
                        child: Opacity(
                          opacity: loading ? 0 : 1,
                          child: thumbnails,
                        ),
                      ),
                    ),
                    if (loading)
                      const Center(child: CircularProgressIndicator()),
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _ThumbnailTile extends ConsumerWidget {
  const _ThumbnailTile({super.key, required this.request});
  final ThumbnailRequest request;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final thumbnail = ref.watch(thumbnailProvider(request));
    final darkMode = ref.watch(brightnessProvider) == Brightness.dark;
    final shader = ref.watch(shaderProvider);
    return ThumbnailCard(
      label: 'Page ${request.page}',
      thumbnail: Container(
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(4)),
        child: thumbnail.when(
          loading: () => const SizedBox.shrink(),
          error: (e, s) => const Center(child: Text('Preview unavailable')),
          data: (bytes) {
            if (bytes == null) return const SizedBox.shrink();
            final image = Image.memory(bytes);
            return darkMode && shader != null
                ? ImageFiltered(
                    imageFilter: ImageFilter.shader(shader),
                    child: image,
                  )
                : image;
          },
        ),
      ),
      onPressed: () {
        final controller = ref.read(pdfViewerControllerProvider);
        if (controller.isReady) controller.goToPage(pageNumber: request.page);
      },
    );
  }
}
