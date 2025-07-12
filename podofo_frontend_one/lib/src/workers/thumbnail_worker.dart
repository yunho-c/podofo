import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;
import 'package:pdfrx/pdfrx.dart';

import 'package:podofo_one/objectbox.g.dart';
import 'package:podofo_one/src/data/objectbox.dart';
import 'package:podofo_one/src/data/thumbnail_entity.dart';

@immutable
class ThumbnailsState {
  const ThumbnailsState({
    this.thumbnails = const {},
    this.isGenerating = const {},
  });

  final Map<String, Map<int, Uint8List>> thumbnails;
  final Map<String, bool> isGenerating;

  ThumbnailsState copyWith({
    Map<String, Map<int, Uint8List>>? thumbnails,
    Map<String, bool>? isGenerating,
  }) {
    return ThumbnailsState(
      thumbnails: thumbnails ?? this.thumbnails,
      isGenerating: isGenerating ?? this.isGenerating,
    );
  }
}

class ThumbnailsNotifier extends StateNotifier<ThumbnailsState> {
  final ObjectBox objectbox;

  ThumbnailsNotifier(this.objectbox) : super(const ThumbnailsState());

  Future<void> retrieveThumbnails(PdfDocument document) async {
    final filePath = document.sourceName;
    if (state.isGenerating[filePath] == true) return;

    state = state.copyWith(
      isGenerating: {...state.isGenerating, filePath: true},
    );

    try {
      final loaded = await _loadFromDatabase(filePath);
      if (!loaded) {
        await _generateAndSave(document);
      }
    } catch (e, s) {
      if (kDebugMode) {
        print('Error ensuring thumbnails for $filePath: $e\n$s');
      }
    } finally {
      state = state.copyWith(
        isGenerating: {...state.isGenerating, filePath: false},
      );
    }
  }

  Future<bool> _loadFromDatabase(String filePath) async {
    final box = objectbox.store.box<ThumbnailEntity>();
    final query = box.query(ThumbnailEntity_.filePath.equals(filePath)).build();
    final existingThumbnails = query.find();
    query.close();

    if (existingThumbnails.isNotEmpty) {
      final newThumbnailsForPdf = <int, Uint8List>{};
      for (final thumbnail in existingThumbnails) {
        newThumbnailsForPdf[thumbnail.pageNumber!] = thumbnail.thumbnailData!;
      }
      state = state.copyWith(
        thumbnails: {...state.thumbnails, filePath: newThumbnailsForPdf},
      );
      return true;
    }
    return false;
  }

  Future<void> _generateAndSave(PdfDocument document) async {
    final filePath = document.sourceName;
    final newThumbnailsForPdf = <int, Uint8List>{};
    final newEntities = <ThumbnailEntity>[];

    for (int i = 1; i <= document.pages.length; i++) {
      final page = document.pages[i - 1];
      final pdfImage = await page.render();
      if (pdfImage == null) continue;

      final image = img.Image.fromBytes(
        width: pdfImage.width,
        height: pdfImage.height,
        bytes: pdfImage.pixels.buffer,
        order: img.ChannelOrder.bgra,
      );
      final thumbnailData = img.encodeJpg(image, quality: 50);

      newEntities.add(
        ThumbnailEntity(
          filePath: filePath,
          pageNumber: i,
          thumbnailData: thumbnailData,
        ),
      );
      newThumbnailsForPdf[i] = thumbnailData;
    }

    objectbox.store.box<ThumbnailEntity>().putMany(newEntities);

    state = state.copyWith(
      thumbnails: {...state.thumbnails, filePath: newThumbnailsForPdf},
    );
  }
}
