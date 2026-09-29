import 'dart:async';
import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../providers/document_provider.dart';
import '../../providers/theme_provider.dart';
import '../../services/document_actions.dart';
import '../../workers/open_graph_worker.dart';

class CustomPdfViewer extends ConsumerStatefulWidget {
  const CustomPdfViewer({super.key});
  @override
  ConsumerState<CustomPdfViewer> createState() => _CustomPdfViewerState();
}

class _CustomPdfViewerState extends ConsumerState<CustomPdfViewer> {
  OverlayEntry? _overlay;
  Timer? _hoverTimer;
  int _generation = 0;

  void _clearHover() {
    _generation++;
    _hoverTimer?.cancel();
    _overlay?.remove();
    _overlay?.dispose();
    _overlay = null;
  }

  @override
  void dispose() {
    _clearHover();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final document = ref.watch(currentDocumentProvider);
    if (document == null) {
      return const Center(
        child: Text('Press the folder icon to pick a PDF file.'),
      );
    }
    final controller = ref.watch(pdfViewerControllerProvider);
    final searcher = ref.watch(pdfTextSearcherProvider);
    final brightness = ref.watch(brightnessProvider);
    final shader = ref.watch(shaderProvider);
    Widget viewer = PdfViewer(
      document.session.lease.reference,
      controller: controller,
      initialPageNumber: document.lastOpenedPage ?? 1,
      params: PdfViewerParams(
        onViewerReady: (pdf, readyController) {
          Future.microtask(() {
            if (mounted) {
              ref.read(viewerReadyProvider.notifier).state = readyController;
            }
          });
        },
        onPageChanged: (page) {
          if (page != null && mounted) {
            ref
                .read(loadedDocumentsProvider.notifier)
                .updateDocumentPage(document.filePath, page);
          }
        },
        pagePaintCallbacks: [
          if (searcher != null) searcher.pageTextMatchPaintCallback,
        ],
        customizeContextMenuItems: (params, items) {
          if (params.textSelectionDelegate.hasSelectedText &&
              document.pdfDocument.permissions?.allowsModifyAnnotations !=
                  false) {
            items.add(
              ContextMenuButtonItem(
                label: 'Highlight',
                onPressed: () {
                  params.dismissContextMenu();
                  DocumentActions.highlight(ref);
                },
              ),
            );
          }
        },
        linkHandlerParams: PdfLinkHandlerParams(
          onLinkTap: (link) async {
            _clearHover();
            try {
              if (link.url != null && canOpenExternalLink(link.url!)) {
                if (!await launchUrl(
                  link.url!,
                  mode: LaunchMode.externalApplication,
                )) {
                  throw StateError('Could not open this link.');
                }
              } else if (link.dest != null) {
                await controller.goToDest(link.dest!);
              } else {
                throw StateError(
                  'Only HTTP and HTTPS external links are supported.',
                );
              }
            } catch (e) {
              if (mounted) DocumentActions.error(ref, e);
            }
          },
        ),
        viewerOverlayBuilder: (context, size, handleLinkTap) => [
          PdfViewerScrollThumb(
            controller: controller,
            orientation: ScrollbarOrientation.right,
            thumbSize: const Size(10, 60),
            thumbBuilder: (context, size, page, controller) => Container(
              width: size.width,
              height: size.height,
              decoration: BoxDecoration(
                color: Colors.gray.shade600.withAlpha(100),
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
        ],
        backgroundColor: brightness == Brightness.dark
            ? const Color(0xffe6e6e6)
            : const Color(0xfffafafa),
      ),
    );
    if (brightness == Brightness.dark && shader != null) {
      viewer = ImageFiltered(
        imageFilter: ImageFilter.shader(shader),
        child: viewer,
      );
    }
    return MouseRegion(
      onHover: _onHover,
      onExit: (_) => _clearHover(),
      child: viewer,
    );
  }

  void _onHover(PointerHoverEvent event) {
    _clearHover();
    final generation = _generation;
    final document = ref.read(currentDocumentProvider);
    final controller = ref.read(pdfViewerControllerProvider);
    if (document == null || !controller.isReady) return;
    final hit = controller.getPdfPageHitTestResult(
      event.localPosition,
      useDocumentLayoutCoordinates: false,
    );
    if (hit == null) return;
    _hoverTimer = Timer(const Duration(milliseconds: 350), () async {
      try {
        final links = await document.session.lease.use(
          (_) => hit.page.loadLinks(),
        );
        if (!mounted || generation != _generation) return;
        for (final link in links) {
          if (!link.rects.any((rect) => rect.containsPoint(hit.offset))) {
            continue;
          }
          final label = link.url == null
              ? 'Page ${link.dest?.pageNumber ?? ''}'
              : linkPreviewLabel(link.url!);
          final size = MediaQuery.sizeOf(context);
          final overlayBox =
              Overlay.of(context).context.findRenderObject() as RenderBox;
          final position = overlayBox.globalToLocal(event.position);
          _overlay = OverlayEntry(
            builder: (context) => Positioned(
              left: (position.dx + 15).clamp(
                0,
                (size.width - 340).clamp(0, double.infinity),
              ),
              top: (position.dy + 15).clamp(
                0,
                (size.height - 110).clamp(0, double.infinity),
              ),
              child: IgnorePointer(
                child: SizedBox(
                  width: 320,
                  child: Card(
                    child: Text(
                      label,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                    ).small(),
                  ),
                ),
              ),
            ),
          );
          Overlay.of(context).insert(_overlay!);
          break;
        }
      } catch (_) {
        // A hover can race tab close or page reload; it is never an app error.
      }
    });
  }
}
