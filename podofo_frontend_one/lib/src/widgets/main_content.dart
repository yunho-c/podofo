import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:podofo_one/src/providers.dart';

class MainContent extends ConsumerWidget {
  const MainContent({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filePath = ref.watch(filePathProvider);
    final pdfViewerController = ref.watch(pdfViewerControllerProvider);
    final theme = ref.watch(themeProvider);
    final bool darkMode = theme == ThemeMode.dark;

    return Expanded(
      child: Scaffold(
        appBar: AppBar(actions: []),
        body: filePath != null
            ? ColorFiltered(
                colorFilter: ColorFilter.mode(
                  Colors.white,
                  darkMode ? BlendMode.difference : BlendMode.dst,
                ),
                child: PdfViewer.file(
                  filePath,
                  controller: pdfViewerController,
                  params: PdfViewerParams(
                    // enableTextSelection: true, // FOR pdfrx 1.2.9
                    textSelectionParams: PdfTextSelectionParams(
                      textSelectionTriggeredBySwipe: true,
                    ), // FOR pdfrx 1.3.0
                    linkHandlerParams: PdfLinkHandlerParams(
                      onLinkTap: (link) {
                        if (link.url != null) {
                          // external web URL
                          launchUrl(link.url!);
                        } else if (link.dest != null) {
                          // internal link
                          pdfViewerController.goToDest(link.dest!);
                        }
                      },
                      linkColor: const Color.fromRGBO(100, 100, 255, 0.01),
                    ),
                    viewerOverlayBuilder: (context, size, handleLinkTap) => [
                      PdfViewerScrollThumb(
                        controller: pdfViewerController,
                        orientation: ScrollbarOrientation.right,
                      ),
                    ],
                    backgroundColor: darkMode
                        ? const Color.fromRGBO(230, 230, 230, 1.0)
                        : const Color.fromRGBO(250, 250, 250, 1.0),
                    pageDropShadow: darkMode
                        ? const BoxShadow(
                            color: Colors.white54,
                            blurRadius: 4,
                            spreadRadius: 0,
                            offset: Offset(0, 4),
                          )
                        : const BoxShadow(
                            color: Colors.black54,
                            blurRadius: 4,
                            spreadRadius: 0,
                            offset: Offset(0, 4),
                          ),
                  ),
                ),
              )
            : const Center(
                child: Text('Press the folder icon to pick a PDF file.'),
              ),
      ),
    );
  }
}
