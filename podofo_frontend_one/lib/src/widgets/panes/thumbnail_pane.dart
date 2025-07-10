import 'dart:ui';
import 'package:flutter/material.dart' show Scaffold;
import 'package:flutter/widgets.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' hide Scaffold;

import 'package:podofo_one/src/data/document_data.dart';
import 'package:podofo_one/src/providers/providers.dart';
import 'package:podofo_one/src/widgets/components/thumbnail_card.dart';

class ThumbnailPane extends ConsumerStatefulWidget {
  const ThumbnailPane({super.key});

  @override
  ConsumerState<ThumbnailPane> createState() => _ThumbnailPaneState();
}

class _ThumbnailPaneState extends ConsumerState<ThumbnailPane> {
  late final PdfViewerController pdfViewerController;
  final List<FocusNode> _focusNodes = [];
  String? _currentDocPath;
  int? _lastHandledPage;
  bool _isNavigating = false;
  bool _inImplicitFocusChange = false;

  @override
  void initState() {
    super.initState();
    pdfViewerController = ref.read(pdfViewerControllerProvider);
  }

  @override
  void dispose() {
    for (var node in _focusNodes) {
      node.dispose();
    }
    super.dispose();
  }

  void _onPageChanged(int pageNumber) {
    if (!_isNavigating) {
      final index = pageNumber - 1;
      if (index >= 0 && index < _focusNodes.length) {
        if (!_focusNodes[index].hasFocus) {
          _inImplicitFocusChange = true;
          _focusNodes[index].requestFocus();
        }
      }
    }
  }

  void _updateFocusNodes(int count) {
    if (_focusNodes.length < count) {
      _focusNodes.addAll(
        List.generate(count - _focusNodes.length, (index) => FocusNode()),
      );
    } else if (_focusNodes.length > count) {
      for (var i = count; i < _focusNodes.length; i++) {
        _focusNodes[i].dispose();
      }
      _focusNodes.removeRange(count, _focusNodes.length);
    }
  }

  void navigate(int pageNumber) {
    _isNavigating = true;
    pdfViewerController.goToPage(pageNumber: pageNumber);
    _isNavigating = false;
  }

  @override
  Widget build(BuildContext context) {
    final currentDoc = ref.watch(currentDocumentProvider);

    ref.listen<Document?>(currentDocumentProvider, (prev, next) {
      if (next != null &&
          next.lastOpenedPage != null &&
          next.lastOpenedPage != _lastHandledPage) {
        _lastHandledPage = next.lastOpenedPage;
        _onPageChanged(next.lastOpenedPage!);
      }
    });

    final brightness = ref.watch(brightnessProvider);
    final bool darkMode = brightness == Brightness.dark;
    final shader = ref.watch(shaderProvider);

    if (currentDoc == null) {
      _currentDocPath = null;
      _lastHandledPage = null;
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
    _lastHandledPage = null;

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
                  navigate(index + 1);
                  // _inImplicitFocusChange = true;
                  // _focusNodes[index].requestFocus();
                },
                onFocus: (isFocused) {
                  if (isFocused) {
                    if (_inImplicitFocusChange) {
                      _inImplicitFocusChange = false;
                    } else {
                      navigate(index + 1);
                    }
                    // pdfViewerController.goToPage(pageNumber: index + 1);
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
