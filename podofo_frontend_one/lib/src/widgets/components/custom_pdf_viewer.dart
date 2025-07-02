import 'dart:async';
import 'dart:ui';
import 'package:flutter/gestures.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:podofo_one/src/providers/providers.dart';

class CustomPdfViewer extends ConsumerStatefulWidget {
  const CustomPdfViewer({super.key});

  @override
  ConsumerState<CustomPdfViewer> createState() => _CustomPdfViewerState();
}

const int linkHoverScanFreq = 300;

class _CustomPdfViewerState extends ConsumerState<CustomPdfViewer> {
  OverlayEntry? _overlayEntry;
  PdfLink? _hoveredLink;
  Timer? _hoverTimer;

  @override
  void dispose() {
    _removeHoverCard();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final currentDocument = ref.watch(currentDocumentProvider);
    final pdfViewerController = ref.watch(pdfViewerControllerProvider);
    final theme = ref.watch(themeProvider);
    final bool darkMode = theme == ThemeMode.dark;
    final shader = ref.watch(shaderProvider);

    Widget buildPdfViewer() {
      if (currentDocument == null) {
        return const Center(child: Text('No document selected'));
      }
      return PdfViewer.file(
        currentDocument.filePath,
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
                  // color: Colors.white54, // material
                  // color: Colors.white, // shadcn
                  color: Color.fromRGBO(255, 255, 255, 0.54), // shadcn OPT2
                  blurRadius: 4,
                  spreadRadius: 0,
                  offset: Offset(0, 4),
                )
              : const BoxShadow(
                  // color: Colors.black54, // material
                  // color: Colors.black, // shadcn
                  color: Color.fromRGBO(0, 0, 0, 0.54), // shadcn OPT2
                  blurRadius: 4,
                  spreadRadius: 0,
                  offset: Offset(0, 4),
                ),
        ),
      );
    }

    Widget body;
    if (currentDocument == null) {
      body = const Center(
        child: Text('Press the folder icon to pick a PDF file.'),
      );
    } else {
      final viewer = darkMode && shader != null
          ? ImageFiltered(
              imageFilter: ImageFilter.shader(shader),
              child: buildPdfViewer(),
            )
          : buildPdfViewer();

      body = MouseRegion(
        onHover: _onHover,
        onExit: (_) => _removeHoverCard(),
        child: viewer,
      );
    }

    return body;
  }

  void _onHover(PointerHoverEvent event) {
    final pdfViewerController = ref.read(pdfViewerControllerProvider);
    if (!pdfViewerController.isReady) return;

    final hitResult = pdfViewerController.getPdfPageHitTestResult(
      event.localPosition,
      useDocumentLayoutCoordinates: false,
    );

    _hoverTimer?.cancel();

    if (hitResult == null) {
      _removeHoverCard();
      return;
    }

    _hoverTimer = Timer(
      const Duration(milliseconds: linkHoverScanFreq),
      () async {
        final links = await hitResult.page.loadLinks();
        PdfLink? foundLink;
        String linkType;
        for (final link in links) {
          for (final rect in link.rects) {
            if (rect.containsPoint(hitResult.offset)) {
              foundLink = link;
              // linkType = link.url != null ? "web" : "internal"; // util
              break;
            }
          }
          if (foundLink != null) break;
        }

        if (!mounted) return;

        if (foundLink != null) {
          if (_hoveredLink != foundLink) {
            _removeHoverCard();
            _hoveredLink = foundLink;
            if (foundLink.url != null) {
              // web link
              _showHoverCard(event.position, foundLink.url!.toString());
            } else if (foundLink.dest != null) {
              // internal link
              _showHoverCard(
                event.position,
                "Page ${foundLink.dest!.pageNumber.toString()}",
              );
            }
          }
        } else {
          _removeHoverCard();
        }
      },
    );
  }

  void _showHoverCard(Offset globalPosition, String url) {
    _overlayEntry = _createOverlayEntry(globalPosition, url);
    Overlay.of(context).insert(_overlayEntry!);
  }

  void _removeHoverCard() {
    _hoverTimer?.cancel();
    if (_overlayEntry != null) {
      _overlayEntry!.remove();
      _overlayEntry = null;
    }
    _hoveredLink = null;
  }

  OverlayEntry _createOverlayEntry(Offset globalPosition, String url) {
    return OverlayEntry(
      builder: (context) => Positioned(
        left: globalPosition.dx + 15,
        top: globalPosition.dy + 15,
        child: IgnorePointer(
          child: Card(
            boxShadow: [
              BoxShadow(
                color: Theme.of(context).colorScheme.primary.withAlpha(50),
                offset: Offset(0, 2),
                blurRadius: 2,
              ),
            ],
            child: Padding(
              padding: const EdgeInsets.all(1.0),
              child: Text(url, style: Theme.of(context).typography.small),
            ),
          ),
        ),
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
