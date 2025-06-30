import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:podofo_one/src/providers/providers.dart';
import 'dart:ui';

class CustomPdfViewer extends ConsumerStatefulWidget {
  const CustomPdfViewer({super.key});

  @override
  ConsumerState<CustomPdfViewer> createState() => _CustomPdfViewerState();
}

class _CustomPdfViewerState extends ConsumerState<CustomPdfViewer> {
  @override
  Widget build(BuildContext context) {
    final filePath = ref.watch(filePathProvider);
    final pdfViewerController = ref.watch(pdfViewerControllerProvider);
    final theme = ref.watch(themeProvider);
    final bool darkMode = theme == ThemeMode.dark;
    final shader = ref.watch(shaderProvider);

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
        body = shader.when(
          data: (fs) => ImageFiltered(
            imageFilter: ImageFilter.shader(fs),
            child: buildPdfViewer(),
          ),
          loading: buildPdfViewer,
          error: (e, s) {
            print(e);
            return buildPdfViewer();
          },
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



// // import 'dart:async';
// import 'package:flutter/gestures.dart';
// import 'package:flutter/material.dart';
// import 'package:flutter_riverpod/flutter_riverpod.dart';
// import 'package:flutter/scheduler.dart';
// import 'package:pdfrx/pdfrx.dart';
// import 'package:url_launcher/url_launcher.dart';
// import 'package:podofo_one/src/providers.dart';

// class AdvancedPdfViewer extends ConsumerStatefulWidget {
//   const AdvancedPdfViewer({super.key});

//   @override
//   ConsumerState<AdvancedPdfViewer> createState() => _AdvancedPdfViewerState();
// }

// class _AdvancedPdfViewerState extends ConsumerState<AdvancedPdfViewer>
//     with SingleTickerProviderStateMixin {
//   // viewer-specific state for user interaction
//   bool _isAutoscrolling = false;
//   Offset _autoscrollOrigin = Offset.zero;
//   Offset _currentMousePosition = Offset.zero;
//   Ticker? _ticker;

//   @override
//   void initState() {
//     super.initState();
//     _ticker = createTicker((elapsed) {
//       _performAutoscroll();
//     });
//   }

//   void _performAutoscroll() {
//     if (!_isAutoscrolling) return;

//     final pdfViewerController = ref.read(pdfViewerControllerProvider);
//     // final scrollController = pdfViewerController.scrollController;
//     // if (scrollController == null || !scrollController.hasClients) return;

//     final double dy = _currentMousePosition.dy - _autoscrollOrigin.dy;

//     const double velocityFactor = 0.2;
//     final double scrollVelocity = dy * velocityFactor;

//     final Offset currentPos = pdfViewerController.centerPosition;
//     final Offset dOffset = Offset(0, dy);

//     // scrollController.jumpTo(scrollController.offset + scrollVelocity);
//     // pdfViewerController. .
//     // pdfViewerController.goTo(currentPos + dOffset);
//   }

//   void _startAutoscroll(PointerDownEvent event) {
//     if (event.buttons != kMiddleMouseButton) return;

//     if (_isAutoscrolling) {
//       _stopAutoscroll();
//       return;
//     }

//     setState(() {
//       _isAutoscrolling = true;
//       _autoscrollOrigin = event.position;
//       _currentMousePosition = event.position;
//     });
//     _ticker?.start();
//   }

//   void _stopAutoscroll() {
//     if (!_isAutoscrolling) return;

//     setState(() {
//       _isAutoscrolling = false;
//     });
//     _ticker?.stop();
//   }

//   @override
//   Widget build(BuildContext context) {
//     final filePath = ref.watch(filePathProvider);
//     final pdfViewerController = ref.watch(pdfViewerControllerProvider);

//     return MouseRegion(
//       cursor: _isAutoscrolling
//           ? SystemMouseCursors.allScroll
//           : SystemMouseCursors.basic,
//       child: Listener(
//         onPointerDown: (event) {
//           if (_isAutoscrolling) {
//             _stopAutoscroll();
//           } else {
//             _startAutoscroll(event);
//           }
//         },
//         onPointerMove: (event) {
//           if (_isAutoscrolling) {
//             _currentMousePosition = event.position;
//           }
//         },
//         // onPointerUp: (event) {
//         //   if (_isPanning) {
//         //     setState(() {
//         //       _isPanning = false;
//         //     });
//         //   }
//         // },
//         child: filePath != null
//             ? PdfViewer.file(
//                 filePath,
//                 controller: pdfViewerController,
//                 params: PdfViewerParams(
//                   // enableTextSelection: true, // FOR pdfrx 1.2.9
//                   textSelectionParams: PdfTextSelectionParams(
//                     textSelectionTriggeredBySwipe: true,
//                   ), // FOR pdfrx 1.3.0
//                   linkHandlerParams: PdfLinkHandlerParams(
//                     onLinkTap: (link) {
//                       if (link.url != null) {
//                         // external web URL
//                         launchUrl(link.url!);
//                       } else if (link.dest != null) {
//                         // internal link
//                         pdfViewerController.goToDest(link.dest!);
//                       }
//                     },
//                     linkColor: Color.fromRGBO(100, 100, 255, 0.01),
//                   ),
//                   onKey: (params, key, isReal) {
//                     const double scrollAmount = 100.0;
//                     const Duration scrollDuration = Duration(milliseconds: 250);
//                     const Curve scrollCurve = Curves.easeOut;

//                     // if (keyEvent.isKeyPressed(LogicalKeyboardKey.arrowDown)) {
//                     //   scrollController.animateTo(
//                     //     scrollController.offset + scrollAmount,
//                     //     duration: scrollDuration,
//                     //     curve: scrollCurve,
//                     //   );
//                     //   return true;
//                     // } else if (keyEvent.isKeyPressed(
//                     //   LogicalKeyboardKey.arrowUp,
//                     // )) {
//                     //   scrollController.animateTo(
//                     //     scrollController.offset - scrollAmount,
//                     //     duration: scrollDuration,
//                     //     curve: scrollCurve,
//                     //   );
//                     //   return true;
//                     // }
//                     // return false;
//                   },
//                 ),
//               )
//             : const Center(
//                 child: Text('Press the folder icon to pick a PDF file.'),
//               ),
//       ),
//     );
//   }
// }
