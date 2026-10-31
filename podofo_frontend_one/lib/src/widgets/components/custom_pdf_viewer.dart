import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart' as flutter;
import 'package:flutter/scheduler.dart' show SchedulerPhase;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../analysis/analysis_controller.dart';
import '../../previews/link_target.dart';
import '../../analysis/equation_controller.dart';
import '../../analysis/analysis_painter.dart';
import '../../providers/analysis_provider.dart';

import '../../providers/document_provider.dart';
import '../../providers/theme_provider.dart';
import '../../providers/user_state_provider.dart';
import '../../providers/narration_provider.dart';
import '../../narration/narration_controller.dart';
import '../../narration/narration_painter.dart';
import '../../services/document_actions.dart';
import '../../services/pdf_navigation_history.dart';
import '../../services/pdf_session.dart';
import '../../workers/open_graph_worker.dart';
import '../../workers/link_preview_worker.dart';
import 'pdf_context_menu_overlay.dart';
import 'pdf_page_layout.dart';
import 'pdf_back_button.dart';
import 'pdf_link_hover_preview.dart';
import 'pdf_selection_menu.dart';

class CustomPdfViewer extends ConsumerStatefulWidget {
  const CustomPdfViewer({super.key});
  @override
  ConsumerState<CustomPdfViewer> createState() => _CustomPdfViewerState();
}

class _CustomPdfViewerState extends ConsumerState<CustomPdfViewer>
    with SingleTickerProviderStateMixin {
  static final _disabledFilter = ImageFilter.blur(sigmaX: 0, sigmaY: 0);

  OverlayEntry? _overlay;
  Timer? _hoverTimer;
  int _generation = 0;
  late final LinkPreviewWorker _previews;
  late PdfViewerController _hoverViewer;
  ui.Image? _previewImage;
  final _selectionPointers = <int>{};
  bool _selectionChanged = false;
  AnnotationMenuRequest? _annotationMenuRequest;
  late final NarrationController _narration;
  Object? _paintedRange;
  int _followRequest = 0;
  Offset? _followOrigin;
  bool _scrollCheckPending = false;
  bool _resetScrollOrigin = false;
  late final AnimationController _linkAnimation;
  ({
    PdfViewerController viewer,
    PdfSession session,
    Matrix4Tween tween,
    VoidCallback? complete,
  })?
  _linkNavigation;
  Matrix4? _lastNavigationMatrix;

  void _cancelLinkNavigation() {
    if (_linkNavigation == null) return;
    _linkAnimation.stop();
    _linkNavigation = null;
    if (mounted) setState(() {});
  }

  void _animateLinkNavigation() {
    final navigation = _linkNavigation;
    if (navigation == null) return;
    final viewer = navigation.viewer;
    if (!mounted ||
        !viewer.isReady ||
        navigation.session.lease.isClosed ||
        !identical(
          ref.read(currentDocumentProvider)?.session,
          navigation.session,
        ) ||
        viewer.value != _lastNavigationMatrix) {
      // A tab change, resize or another navigation takes precedence. In
      // particular, an interrupted Back must keep its return point.
      _cancelLinkNavigation();
      return;
    }
    viewer.value = navigation.tween.transform(
      Curves.easeInOut.transform(_linkAnimation.value),
    );
    _lastNavigationMatrix = viewer.value.clone();
  }

  void _navigateLink(
    PdfViewerController viewer,
    PdfSession session,
    Matrix4 destination, {
    VoidCallback? complete,
  }) {
    _clearHover();
    if (identical(session, _narration.source?.documentId)) {
      _narration.setFollowText(false);
    }
    // Own this short animation: pdfrx's goTo future can remain pending when
    // another goTo or disposal cancels it. History must never stay locked.
    unawaited(viewer.goTo(viewer.value.clone(), duration: Duration.zero));
    final target = viewer.calcMatrixForClampedToNearestBoundary(
      destination,
      viewSize: viewer.viewSize,
    );
    if (MediaQuery.disableAnimationsOf(context)) {
      viewer.value = target;
      complete?.call();
      setState(() {});
      return;
    }
    _lastNavigationMatrix = viewer.value.clone();
    _linkNavigation = (
      viewer: viewer,
      session: session,
      tween: Matrix4Tween(begin: viewer.value.clone(), end: target),
      complete: complete,
    );
    setState(() {});
    _linkAnimation.forward(from: 0);
  }

  void _followInternalLink(
    PdfViewerController viewer,
    PdfSession session,
    PdfDest destination,
  ) {
    if (_linkNavigation != null ||
        !viewer.isReady ||
        session.lease.isClosed ||
        !identical(ref.read(currentDocumentProvider)?.session, session)) {
      return;
    }
    if (destination.pageNumber < 1 ||
        destination.pageNumber > viewer.layout.pageLayouts.length) {
      throw StateError('This link points to a page that is not in this PDF.');
    }
    final target = viewer.calcMatrixForDest(destination);
    if (target == null || target.storage.any((value) => !value.isFinite)) {
      throw StateError('This PDF link has an unsupported destination.');
    }
    final position = PdfReadingPosition.capture(viewer);
    _navigateLink(viewer, session, target);
    session.navigationHistory.remember(position);
  }

  void _goBack() {
    final document = ref.read(currentDocumentProvider);
    final viewer = ref.read(pdfViewerControllerProvider);
    if (_linkNavigation != null ||
        !viewer.isReady ||
        document == null ||
        document.session.lease.isClosed) {
      return;
    }
    final history = document.session.navigationHistory;
    final position = history.previous;
    if (position == null) return;
    try {
      _navigateLink(
        viewer,
        document.session,
        position.matrixFor(viewer),
        complete: () {
          history.returnedTo(position);
          viewer.requestFocus();
        },
      );
    } catch (e) {
      DocumentActions.error(ref, e);
    }
  }

  // Inspect the resulting viewport, not pointer travel: selecting text must not
  // suspend following. Only user input schedules this check; ensureVisible does not.
  void _checkUserScroll({bool zooming = false}) {
    _resetScrollOrigin = _resetScrollOrigin || zooming;
    if (_scrollCheckPending) return;
    _scrollCheckPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollCheckPending = false;
      final reset = _resetScrollOrigin;
      _resetScrollOrigin = false;
      if (!mounted) return;
      final viewer = ref.read(pdfViewerControllerProvider);
      final document = ref.read(currentDocumentProvider);
      if (!viewer.isReady ||
          document == null ||
          !identical(document.session, _narration.source?.documentId)) {
        return;
      }
      final center = viewer.visibleRect.center;
      if (reset || _followOrigin == null) {
        _followOrigin = center;
      } else if (_narration.followText &&
          (center - _followOrigin!).distance * viewer.currentZoom >= 32) {
        _narration.setFollowText(false);
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void initState() {
    super.initState();
    _previews = LinkPreviewWorker(
      render: ref.read(linkPreviewRendererProvider),
    );
    _hoverViewer = ref.read(pdfViewerControllerProvider);
    _hoverViewer.addListener(_clearHover);
    ref.listenManual(pdfViewerControllerProvider, (previous, next) {
      _hoverViewer.removeListener(_clearHover);
      _hoverViewer = next;
      _hoverViewer.addListener(_clearHover);
      _clearHover();
    });
    ref.listenManual(
      currentDocumentProvider.select(
        (doc) => (doc?.session, doc?.session.revision),
      ),
      (previous, next) {
        _clearHover();
        _previews.reset();
      },
    );
    _linkAnimation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    )..addListener(_animateLinkNavigation);
    _linkAnimation.addStatusListener((status) {
      if (status != AnimationStatus.completed) return;
      final navigation = _linkNavigation;
      _linkNavigation = null;
      navigation?.complete?.call();
      if (mounted) setState(() {});
    });
    _narration = ref.read(narrationControllerProvider);
    _narration.addListener(_onNarrationChanged);
    _narration.scrubPreview.addListener(_onScrubPreviewChanged);
  }

  void _onScrubPreviewChanged() {
    if (!mounted) return;
    // A stale drag can be cleared while the timeline is rebuilding.
    if (WidgetsBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _onScrubPreviewChanged(),
      );
      return;
    }
    final viewer = ref.read(pdfViewerControllerProvider);
    if (viewer.isReady) viewer.invalidate();
  }

  void _onNarrationChanged() {
    if (!mounted) return;
    final document = ref.read(currentDocumentProvider);
    final viewer = ref.read(pdfViewerControllerProvider);
    if (document == null || !viewer.isReady) return;
    final state = _narration.snapshot;
    final requested = _followRequest != _narration.followRequest;
    _followRequest = _narration.followRequest;
    final key = (
      _narration.source,
      state?.start,
      state?.end,
      _narration.terminal,
      _narration.followText,
      _narration.followRequest,
      _narration.documentSeekTarget,
    );
    if (_paintedRange == key) return;
    _paintedRange = key;
    viewer.invalidate(); // Repaint a sentence change; never rebuild for audio ticks.
    if (_narration.previewingDocument ||
        !_narration.followText ||
        (_scrollCheckPending && !requested) ||
        (_narration.terminal && !requested) ||
        !identical(document.session, _narration.source?.documentId)) {
      return;
    }
    final anchor = _narration.currentAnchor;
    final passage = _narration.source?.passage;
    if (anchor == null ||
        passage == null ||
        state?.start == null ||
        state?.end == null) {
      return;
    }
    final rectangles = passage.rectangles(
      anchor.page,
      state!.start!,
      state.end!,
    );
    if (rectangles.isEmpty) return;
    final page = document.pdfDocument.pages[anchor.page - 1];
    final layout = viewer.layout.pageLayouts[anchor.page - 1];
    final target = rectangles.first
        .toRect(page: page, scaledPageSize: layout.size)
        .translate(layout.left, layout.top);
    _followOrigin = viewer.visibleRect.center;
    if (!viewer.visibleRect.contains(target.center)) {
      unawaited(
        viewer.ensureVisible(target, duration: Duration.zero).then((_) {
          if (mounted && viewer.isReady) {
            _followOrigin = viewer.visibleRect.center;
          }
        }),
      );
    }
  }

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
    _cancelLinkNavigation();
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
    _hoverTimer = null;
    _previews.cancel();
    _overlay?.remove();
    _overlay?.dispose();
    _overlay = null;
    _previewImage?.dispose();
    _previewImage = null;
  }

  AnalysisController? _analysis;
  EquationController? _equations;
  (String?, bool)? _paintedEquation;
  Object? _analysisPage;
  bool? _analysisVisible;
  bool _analysisRepaintQueued = false;
  void _analysisChanged() {
    final equation = (
      _equations?.selected?.identity,
      _equations?.speaking ?? false,
    );
    if (!mounted ||
        (identical(_analysisPage, _analysis?.visibleSnapshot) &&
            _analysisVisible == _analysis?.showRegions &&
            _paintedEquation == equation)) {
      return;
    }
    _analysisPage = _analysis?.visibleSnapshot;
    _analysisVisible = _analysis?.showRegions;
    _paintedEquation = equation;
    if (_analysisRepaintQueued) return;
    _analysisRepaintQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _analysisRepaintQueued = false;
      if (!mounted) return;
      final controller = ref.read(pdfViewerControllerProvider);
      if (controller.isReady) controller.invalidate();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    _analysis?.removeListener(_analysisChanged);
    _equations?.removeListener(_analysisChanged);
    _linkAnimation.dispose();
    _narration.removeListener(_onNarrationChanged);
    _narration.scrubPreview.removeListener(_onScrubPreviewChanged);
    _clearHover();
    _hoverViewer.removeListener(_clearHover);
    _previews.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final equations = ref.watch(equationControllerProvider);
    if (!identical(_equations, equations)) {
      _equations?.removeListener(_analysisChanged);
      _equations = equations;
      _equations?.addListener(_analysisChanged);
    }
    final analysis = ref.watch(analysisControllerProvider).asData?.value;
    if (!identical(_analysis, analysis)) {
      _analysis?.removeListener(_analysisChanged);
      _analysis = analysis;
      _analysis?.addListener(_analysisChanged);
    }
    final document = ref.watch(currentDocumentProvider);
    if (_annotationMenuRequest?.document.session != document?.session) {
      _annotationMenuRequest = null;
    }
    if (document == null) {
      return const Center(
        child: Text('Press the plus icon to pick a PDF file.'),
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
        onViewSizeChanged: (_, _, _) {
          _clearHover();
          _checkUserScroll(zooming: true);
        },
        onInteractionUpdate: (details) =>
            _checkUserScroll(zooming: (details.scale - 1).abs() > .001),
        onKey: (params, key, isRealKeyPress) {
          if (isRealKeyPress) {
            _clearHover();
            _cancelLinkNavigation();
          }
          if (isRealKeyPress &&
              identical(document.session, _narration.source?.documentId) &&
              const [
                LogicalKeyboardKey.pageUp,
                LogicalKeyboardKey.pageDown,
                LogicalKeyboardKey.home,
                LogicalKeyboardKey.end,
                LogicalKeyboardKey.space,
                LogicalKeyboardKey.arrowUp,
                LogicalKeyboardKey.arrowDown,
                LogicalKeyboardKey.arrowLeft,
                LogicalKeyboardKey.arrowRight,
              ].contains(key)) {
            _narration.setFollowText(false);
          }
          return null; // Retain the viewer's normal keyboard navigation.
        },
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
              _paintedRange = null;
              _followOrigin = readyController.visibleRect.center;
              _onNarrationChanged();
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
          if (analysis != null)
            (canvas, rect, page) => paintAnalysis(
              canvas,
              rect,
              page,
              analysis,
              document.session,
              selected: equations?.selected,
              speaking: equations?.speaking ?? false,
            ),
          if (searcher != null) searcher.pageTextMatchPaintCallback,
          (canvas, rect, page) =>
              paintNarration(canvas, rect, page, _narration, document.session),
        ],
        textSelectionParams: PdfTextSelectionParams(
          onTextSelectionChange: (selection) {
            _selectionChanged = selection.hasSelectedText;
            _applyHighlightMode();
          },
        ),
        // pdfrx only positions non-positional menus when text is selected.
        // Return Flutter's Positioned so it recognizes our layout in both cases.
        buildContextMenu: (context, params) {
          final request =
              _annotationMenuRequest?.document.session == document.session
              ? _annotationMenuRequest
              : null;
          return flutter.Positioned.fill(
            key: const ValueKey('pdf-context-menu'),
            child: PdfContextMenuOverlay(
              anchor: params.anchorA,
              child: PdfSelectionMenu(
                params: params,
                annotationRequest: request,
                onDismiss: () {
                  if (identical(_annotationMenuRequest, request)) {
                    _annotationMenuRequest = null;
                  }
                },
                onHighlight: (color) =>
                    DocumentActions.highlight(ref, color: color),
                onUnderline: () => DocumentActions.underline(ref),
                twoPageView: document.twoPageView,
                onTwoPageViewChanged: _setTwoPageView,
              ),
            ),
          );
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
                _followInternalLink(controller, document.session, link.dest!);
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
        viewerOverlayBuilder: (context, size, handleLinkTap) {
          final margin = controller.params.boundaryMargin;
          final documentHeight =
              controller.documentSize.height +
              (margin == null || margin.vertical.isInfinite
                  ? 0
                  : margin.vertical);
          // visibleRect is in document coordinates, so its fraction accounts
          // for zoom. Match the scroll range used by PdfViewerScrollThumb.
          final minimumHeight = math.min(40.0, size.height);
          final thumbHeight = documentHeight > 0
              ? (size.height * controller.visibleRect.height / documentHeight)
                    .clamp(minimumHeight, size.height)
              : minimumHeight;
          return [
            PdfViewerScrollThumb(
              controller: controller,
              orientation: ScrollbarOrientation.right,
              thumbSize: Size(10, thumbHeight),
              thumbBuilder: (context, size, page, controller) => Container(
                width: size.width,
                height: size.height,
                decoration: BoxDecoration(
                  color: Colors.gray.shade600.withAlpha(100),
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
          ];
        },
        backgroundColor: brightness == Brightness.dark
            ? const Color(0xffe6e6e6)
            : const Color(0xfffafafa),
      ),
    );
    final invert = brightness == Brightness.dark && shader != null;
    final content = MouseRegion(
      onHover: _onHover,
      onExit: (_) => _clearHover(),
      // Keep the viewer mounted so theme/inversion changes preserve its viewport.
      child: ImageFiltered(
        enabled: invert,
        imageFilter: invert ? ImageFilter.shader(shader) : _disabledFilter,
        child: Listener(
          onPointerSignal: (event) {
            _clearHover();
            _cancelLinkNavigation();
            if (event is PointerScrollEvent) {
              _checkUserScroll(
                zooming: HardwareKeyboard.instance.isControlPressed,
              );
            } else if (event is PointerScaleEvent) {
              _checkUserScroll(zooming: true);
            }
          },
          onPointerMove: (_) {
            _cancelLinkNavigation();
            _checkUserScroll();
          },
          onPointerDown: (event) {
            _clearHover();
            _annotationMenuRequest = null;
            if (event.buttons == kSecondaryMouseButton && controller.isReady) {
              final point = controller.globalToDocument(event.position);
              final hit = point == null
                  ? null
                  : controller.getPdfPageHitTestResult(
                      point,
                      useDocumentLayoutCoordinates: true,
                    );
              if (hit != null) {
                _annotationMenuRequest = AnnotationMenuRequest(
                  document,
                  hit.page.pageNumber,
                  hit.offset,
                );
              }
            }
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
                // Anchor to the click, without following or flipping around
                // the viewer's full-size widget. Overflow is clamped instead.
                follow: false,
                alignment: Alignment.topLeft,
                offset: Offset.zero,
                margin: EdgeInsets.zero,
                allowInvertHorizontal: false,
                allowInvertVertical: false,
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
    return Stack(
      children: [
        content,
        if (document.session.navigationHistory.previous != null)
          Positioned(
            top: 0,
            left: 0,
            child: PdfBackButton(
              onPressed: _linkNavigation == null && controller.isReady
                  ? _goBack
                  : null,
            ),
          ),
      ],
    );
  }

  void _onHover(PointerHoverEvent event) {
    _clearHover();
    final generation = _generation;
    final document = ref.read(currentDocumentProvider);
    final controller = ref.read(pdfViewerControllerProvider);
    if (document == null ||
        document.session.lease.isClosed ||
        !controller.isReady) {
      return;
    }
    final session = document.session;
    final revision = session.revision;
    bool isCurrent() =>
        mounted &&
        generation == _generation &&
        !session.lease.isClosed &&
        session.revision == revision &&
        identical(ref.read(currentDocumentProvider)?.session, session) &&
        identical(ref.read(pdfViewerControllerProvider), controller);
    final hit = controller.getPdfPageHitTestResult(
      event.localPosition,
      useDocumentLayoutCoordinates: false,
    );
    if (hit == null) return;
    _hoverTimer = Timer(const Duration(milliseconds: 350), () async {
      try {
        if (!isCurrent()) return;
        final links = await session.readLocked((pdf) async {
          if (!isCurrent()) return const <PdfLink>[];
          return pdf.pages[hit.page.pageNumber - 1].loadLinks();
        });
        if (!mounted || !isCurrent()) return;
        final link = links
            .where(
              (link) =>
                  link.rects.any((rect) => rect.containsPoint(hit.offset)),
            )
            .firstOrNull;
        if (link == null) return;
        var label = link.url == null
            ? 'Page ${link.dest?.pageNumber ?? ''}'
            : linkPreviewLabel(link.url!);
        final overlayBox =
            Overlay.of(context).context.findRenderObject() as RenderBox;
        final position = overlayBox.globalToLocal(event.position);
        _overlay = OverlayEntry(
          builder: (context) => PdfLinkHoverPreview(
            anchor: position,
            label: label,
            image: _previewImage,
          ),
        );
        Overlay.of(context).insert(_overlay!);
        // Only actual internal PDF destinations can request a visual preview.
        // URLs and unsupported destinations retain the existing text tooltip.
        if (link.url == null && link.dest != null) {
          final ratio = boundedPreviewPixelRatio(
            MediaQuery.devicePixelRatioOf(context),
          );
          final request = LinkPreviewRequest(
            session: session,
            sourcePage: hit.page.pageNumber,
            annotationIndex: links.indexOf(link),
            sourceRects: link.rects,
            destination: link.dest!,
            pixelRatio: ratio,
            maxSize: PdfLinkHoverPreview.rasterSize(overlayBox.size),
          );
          final image = await _previews.load(
            session,
            link.dest!,
            pixelRatio: ratio,
            request: request,
            onRefinement: (image, target) {
              if (!isCurrent()) {
                image.dispose();
                return;
              }
              final previous = _previewImage;
              _previewImage = image;
              final first = target.parts.first.page,
                  last = target.parts.last.page;
              label =
                  '${target.label} · ${first == last ? 'Page $first' : 'Pages $first–$last'}';
              previous?.dispose();
              _overlay?.markNeedsBuild();
            },
            repository: _analysis?.previewRepository,
          );
          if (!isCurrent()) {
            image?.dispose();
            return;
          }
          _previewImage = image;
          _overlay?.markNeedsBuild();
        }
      } catch (_) {
        // A hover can race tab close or page reload; it is never an app error.
      }
    });
  }
}
