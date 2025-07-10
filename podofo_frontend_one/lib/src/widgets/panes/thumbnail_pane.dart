import 'dart:ui';
import 'package:flutter/material.dart' show Scaffold;
import 'package:flutter/widgets.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' hide Scaffold;

import 'package:podofo_one/src/providers/providers.dart';
import 'package:podofo_one/src/widgets/components/thumbnail_card.dart';

class ThumbnailPane extends ConsumerStatefulWidget {
  const ThumbnailPane({super.key});

  @override
  ConsumerState<ThumbnailPane> createState() => _ThumbnailPaneState();
}

class _ThumbnailPaneState extends ConsumerState<ThumbnailPane> {
  late final PdfViewerController _pdfViewerController;
  final List<FocusNode> _focusNodes = [];
  String? _currentDocPath;

  @override
  void initState() {
    super.initState();
    _pdfViewerController = ref.read(pdfViewerControllerProvider);
    // _pdfViewerController.pageListenable.addListener(_onPageChanged);
  }

  @override
  void dispose() {
    // _pdfViewerController.pageListenable.removeListener(_onPageChanged);
    for (var node in _focusNodes) {
      node.dispose();
    }
    super.dispose();
  }

  void _onPageChanged() {
    if (!mounted) return;
    final pageNumber = _pdfViewerController.pageNumber;
    if (pageNumber == null) return;
    final index = pageNumber - 1;
    if (index >= 0 && index < _focusNodes.length) {
      if (!_focusNodes[index].hasFocus) {
        _focusNodes[index].requestFocus();
      }
    }
  }

  void _updateFocusNodes(int count) {
    if (_focusNodes.length != count) {
      for (var node in _focusNodes) {
        node.dispose();
      }
      _focusNodes.clear();
      _focusNodes.addAll(List.generate(count, (index) => FocusNode()));
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentDoc = ref.watch(currentDocumentProvider);
    final brightness = ref.watch(brightnessProvider);
    final bool darkMode = brightness == Brightness.dark;
    final shader = ref.watch(shaderProvider);

    if (currentDoc == null) {
      _currentDocPath = null;
      return const Center(child: Text('No document loaded'));
    }

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

    _updateFocusNodes(thumbnails.length);

    if (_currentDocPath != currentDoc.filePath) {
      _currentDocPath = currentDoc.filePath;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        // final pageNumber =
        //     _pdfViewerController.pageNumber ?? currentDoc.lastOpenedPage ?? 1;
        final pageNumber = currentDoc.lastOpenedPage ?? 1;
        final index = pageNumber - 1;
        if (index >= 0 && index < _focusNodes.length) {
          if (!_focusNodes[index].hasFocus) {
            _focusNodes[index].requestFocus();
          }
        }
      });
    }

    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(8.0),
        child: FocusTraversalGroup(
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
                focusNode: _focusNodes[index],
                thumbnail: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: imageWidget,
                ),
                label: '${pageNumber + 1}',
                onPressed: () {
                  if (_pdfViewerController.isReady) {
                    _pdfViewerController.goToPage(pageNumber: index + 1);
                  }
                },
              );
            },
          ),
        ),
      ),
    );
  }
}
