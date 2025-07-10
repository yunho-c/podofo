import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'package:podofo_one/src/data/document_data.dart';
import 'package:podofo_one/src/providers/providers.dart';
import 'package:podofo_one/src/widgets/components/thumbnail_card.dart';

class ThumbnailPane extends ConsumerStatefulWidget {
  const ThumbnailPane({super.key});

  @override
  ConsumerState<ThumbnailPane> createState() => _ThumbnailPaneState();
}

class _ThumbnailPaneState extends ConsumerState<ThumbnailPane> {
  List<FocusNode> _focusNodes = [];
  bool _isNavigating = false;
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    final doc = ref.read(currentDocumentProvider);
    if (doc != null) {
      _updateFocusNodes(doc.pdfDocument.pages.length);
    }

    // Reload FocusNodes if more of PdfDocument is lazily loaded (NOTE: don't remove)
    // ref.listen<Document?>(currentDocumentProvider, (previous, next) {
    //   final prevPageCount = previous?.pdfDocument.pages.length;
    //   final nextPageCount = next?.pdfDocument.pages.length;
    //   if (mounted && prevPageCount != nextPageCount) {
    //     setState(() {
    //       _updateFocusNodes(nextPageCount ?? 0);
    //     });
    //   }
    // });
  }

  // TODO: handle change of currentDocument (probably rebuild? or reload)

  // @override
  // void didChangeDependencies() {
  //   // TODO: implement didChangeDependencies
  //   super.didChangeDependencies();
  // }

  void _updateFocusNodes(int count) {
    _disposeFocusNodes();
    _focusNodes = List.generate(count, (_) => FocusNode());
  }

  void _disposeFocusNodes() {
    for (final node in _focusNodes) {
      node.dispose();
    }
  }

  @override
  void dispose() {
    _disposeFocusNodes();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final doc = ref.watch(currentDocumentProvider);
    // Enable auto-focusing on current page
    ref.listen(currentDocumentProvider, ((previous, next) {
      final int currentPage = next?.lastOpenedPage ?? 0;
      if (mounted &&
          !_isNavigating &&
          currentPage != _selectedIndex &&
          _focusNodes.isNotEmpty &&
          currentPage < _focusNodes.length &&
          _focusNodes[currentPage].canRequestFocus) {
        _focusNodes[currentPage].requestFocus();
      }
    }));

    if (doc == null) {
      return const Center(child: Text('No document loaded'));
    }

    final currentPage = doc.lastOpenedPage ?? 0;
    final brightness = ref.watch(brightnessProvider);
    final bool darkMode = brightness == Brightness.dark;
    final shader = ref.watch(shaderProvider);
    final thumbnailsState = ref.watch(thumbnailsProvider);
    final thumbnails = thumbnailsState.thumbnails[doc.filePath];
    final isGenerating = thumbnailsState.isGenerating[doc.filePath] ?? false;
    final pdfViewerController = ref.read(pdfViewerControllerProvider);

    if (isGenerating && (thumbnails == null || thumbnails.isEmpty)) {
      return const Center(child: CircularProgressIndicator());
    }

    if (thumbnails == null || thumbnails.isEmpty) {
      return const Center(child: Text('No thumbnails available.'));
    }

    return Scaffold(
      child: Padding(
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
                focusNode: _focusNodes[pageNumber],
                thumbnail: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: imageWidget,
                ),
                label: '${pageNumber + 1}',
                onPressed: () async {
                  _isNavigating = true;
                  _selectedIndex = pageNumber;
                  await pdfViewerController.goToPage(pageNumber: pageNumber);
                  _isNavigating = false;
                },
                onFocus: (hasFocus) async {
                  if (hasFocus) {
                    if (pdfViewerController.isReady) {
                      _isNavigating = true;
                      _selectedIndex = pageNumber;
                      await pdfViewerController.goToPage(
                        pageNumber: pageNumber,
                      );
                    }
                    _isNavigating = false;
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
