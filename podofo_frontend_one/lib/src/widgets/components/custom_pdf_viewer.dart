import 'dart:async';
import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../providers/document_provider.dart';
import '../../providers/theme_provider.dart';
import '../../providers/user_state_provider.dart';
import '../../services/document_actions.dart';
import '../../workers/open_graph_worker.dart';
import 'pdf_page_layout.dart';
import 'pdf_selection_menu.dart';

class CustomPdfViewer extends ConsumerStatefulWidget {
  const CustomPdfViewer({super.key});
  @override
  ConsumerState<CustomPdfViewer> createState() => _CustomPdfViewerState();
}

class _CustomPdfViewerState extends ConsumerState<CustomPdfViewer> {
  static final _disabledFilter = ImageFilter.blur(sigmaX: 0, sigmaY: 0);

  OverlayEntry? _overlay;
  Timer? _hoverTimer;
  int _generation = 0;
  final _selectionPointers = <int>{};
  bool _selectionChanged = false;

  void _fitPageView(PdfViewerController controller, int page, bool twoPages) {
    if (!mounted || !controller.isReady) return;
    final bounds = pageViewBounds(controller.layout, page, twoPages: twoPages);
    unawaited(
      controller.goTo(
        controller.calcMatrixForRect(bounds.inflate(controller.params.margin)),
        duration: Duration.zero,
      ),
    );
  }

  Future<void> _setTwoPageView(bool enabled) async {
    final document = ref.read(currentDocumentProvider);
    final controller = ref.read(pdfViewerControllerProvider);
    if (document == null ||
        document.twoPageView == enabled ||
        !controller.isReady) {
      return;
    }
    final page = controller.pageNumber ?? document.lastOpenedPage ?? 1;
    _clearHover();
    ref
        .read(loadedDocumentsProvider.notifier)
        .setTwoPageView(document.filePath, enabled);
    // Wait for pdfrx to apply the new layout and its own viewport adjustment.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || ref.read(pdfViewerControllerProvider) != controller) return;
    _fitPageView(controller, page, enabled);
  }

  void _applyHighlightMode() {
    if (!mounted || !_selectionChanged || _selectionPointers.isNotEmpty) return;
    if (!ref.read(userStateNotifierProvider).highlightModeEnabled) return;
    final controller = ref.read(pdfViewerControllerProvider);
    if (!controller.isReady ||
        !controller.textSelectionDelegate.hasSelectedText) {
      return;
    }
    _selectionChanged = false;
    unawaited(DocumentActions.highlight(ref));
  }

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
    final viewer = PdfViewer(
      document.session.lease.reference,
      controller: controller,
      initialPageNumber: document.lastOpenedPage ?? 1,
      params: PdfViewerParams(
        layoutPages: document.twoPageView ? layoutTwoPages : null,
        sizeDelegateProvider: document.twoPageView
            ? const PdfViewerSizeDelegateProviderLegacy(
                useAlternativeFitScaleAsMinScale: false,
              )
            : null,
        pageDropShadow: const BoxShadow(
          color: Color(0x0C000000),
          blurRadius: 8,
          offset: Offset(0, 0.5),
        ),
        onViewerReady: (pdf, readyController) {
          Future.microtask(() {
            if (mounted) {
              ref.read(viewerReadyProvider.notifier).state = readyController;
              if (document.twoPageView) {
                _fitPageView(
                  readyController,
                  document.lastOpenedPage ?? 1,
                  true,
                );
              }
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
        textSelectionParams: PdfTextSelectionParams(
          onTextSelectionChange: (selection) {
            _selectionChanged = selection.hasSelectedText;
            _applyHighlightMode();
          },
        ),
        buildContextMenu: (context, params) => PdfSelectionMenu(
          params: params,
          onHighlight: (color) => DocumentActions.highlight(ref, color: color),
          twoPageView: document.twoPageView,
          onTwoPageViewChanged: _setTwoPageView,
        ),
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
    final invert = brightness == Brightness.dark && shader != null;
    return MouseRegion(
      onHover: _onHover,
      onExit: (_) => _clearHover(),
      // Keep the viewer mounted so theme/inversion changes preserve its viewport.
      child: ImageFiltered(
        enabled: invert,
        imageFilter: invert ? ImageFilter.shader(shader) : _disabledFilter,
        child: Listener(
          onPointerDown: (event) {
            if (event.buttons == kPrimaryButton) {
              _selectionPointers.add(event.pointer);
            }
          },
          onPointerUp: (event) {
            _selectionPointers.remove(event.pointer);
            Future.microtask(_applyHighlightMode);
          },
          onPointerCancel: (event) {
            _selectionPointers.remove(event.pointer);
            _selectionChanged = false;
          },
          // pdfrx handles clicks within its transformed document. Also offer
          // layout controls in the surrounding padding when zoomed out.
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onSecondaryTapUp: (details) {
              _clearHover();
              showDropdown(
                context: context,
                position: details.globalPosition,
                builder: (context) => DropdownMenu(
                  children: pdfPageLayoutMenuItems(
                    twoPageView: document.twoPageView,
                    onChanged: _setTwoPageView,
                  ),
                ),
              );
            },
            child: viewer,
          ),
        ),
      ),
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
