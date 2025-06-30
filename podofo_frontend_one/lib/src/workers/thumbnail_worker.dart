import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;
import 'package:pdfrx/pdfrx.dart';

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
  ThumbnailsNotifier() : super(const ThumbnailsState());

  Future<void> generateThumbnails(String filePath) async {
    if (state.isGenerating[filePath] == true) return;

    state = state.copyWith(
      isGenerating: {...state.isGenerating, filePath: true},
    );

    try {
      final document = await PdfDocument.openFile(filePath);
      final newThumbnailsForPdf = <int, Uint8List>{};
      for (int i = 1; i <= document.pages.length; i++) {
        final page = document.pages[i - 1];
        final pdfImage = await page.render();
        final image = img.Image.fromBytes(
          width: pdfImage!.width,
          height: pdfImage.height,
          bytes: pdfImage.pixels.buffer,
          order: img.ChannelOrder.rgba,
        );
        final imageBytes = img.encodeJpg(image, quality: 50);
        newThumbnailsForPdf[i] = imageBytes;
      }

      final newThumbnails = {
        ...state.thumbnails,
        filePath: newThumbnailsForPdf,
      };
      state = state.copyWith(thumbnails: newThumbnails);
    } catch (e) {
      if (kDebugMode) {
        print('Error generating thumbnails for $filePath: $e');
      }
    } finally {
      state = state.copyWith(
        isGenerating: {...state.isGenerating, filePath: false},
      );
    }
  }
}
