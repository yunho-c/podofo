import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:podofo_one/src/providers.dart';
import 'dart:ui';

const ColorFilter _differenceDarkModeColorFilter = ColorFilter.mode(
  Colors.white,
  BlendMode.difference,
);

const ColorFilter _luminosityDarkModeColorFilter = ColorFilter.matrix(<double>[
  // R G  B  A  Const
  -0.2126, -0.7152, -0.0722, 0, 255, // Red channel
  -0.2126, -0.7152, -0.0722, 0, 255, // Green channel
  -0.2126, -0.7152, -0.0722, 0, 255, // Blue channel
  0, 0, 0, 1, 0, // Alpha channel
]);

/// A color matrix that approximates a hue-preserving color inversion.
///
/// This matrix is a heuristic based on the common CSS filter combination
/// `invert(1) hue-rotate(180deg)`. It is not as accurate as a full
/// HSL-based conversion (like the shader method) but is much simpler
/// to implement and works well for many use cases.
///
/// It correctly inverts luminance (black <-> white) while making a
/// strong attempt to return colors to their original hue.
const ColorFilter _heuristicDarkModeColorFilter = ColorFilter.matrix(<double>[
  // R     G     B     A  Const
  -0.574, 1.430, 0.144, 0, 0, // Red channel
  0.426, -0.430, 0.144, 0, 0, // Green channel
  0.426, 1.430, -0.856, 0, 0, // Blue channel
  0, 0, 0, 1, 0, // Alpha channel
]);

class MainContent extends ConsumerStatefulWidget {
  const MainContent({super.key});

  @override
  ConsumerState<MainContent> createState() => _MainContentState();
}

class _MainContentState extends ConsumerState<MainContent> {
  // FragmentShader? _shader;
  FragmentShader? _shader;

  @override
  void initState() {
    super.initState();
    _loadShader();
  }

  Future<void> _loadShader() async {
    try {
      final program = await FragmentProgram.fromAsset('shaders/invert.frag');
      // final program = await FragmentProgram.fromAsset('shaders/default.frag');
      setState(() {
        _shader = program.fragmentShader();
      });
    } catch (e) {
      // Handle shader loading error if necessary
      print(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final filePath = ref.watch(filePathProvider);
    final pdfViewerController = ref.watch(pdfViewerControllerProvider);
    final theme = ref.watch(themeProvider);
    final bool darkMode = theme == ThemeMode.dark;

    Widget buildPdfViewer() {
      return PdfViewer.file(
        filePath!,
        controller: pdfViewerController,
        params: PdfViewerParams(
          textSelectionParams: const PdfTextSelectionParams(
            textSelectionTriggeredBySwipe: true,
          ),
          linkHandlerParams: PdfLinkHandlerParams(
            onLinkTap: (link) {
              if (link.url != null) {
                launchUrl(link.url!);
              } else if (link.dest != null) {
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
      );
    }

    Widget body;
    if (filePath == null) {
      body = const Center(
        child: Text('Press the folder icon to pick a PDF file.'),
      );
    } else {
      if (darkMode) {
        body = ImageFiltered(
          imageFilter: ImageFilter.shader(_shader!),
          child: buildPdfViewer(),
        );
      } else {
        body = buildPdfViewer();
      }
    }

    return Expanded(
      child: Scaffold(
        appBar: AppBar(actions: const []),
        body: body,
      ),
    );
  }
}
