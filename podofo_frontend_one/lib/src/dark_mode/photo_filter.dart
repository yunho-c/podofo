import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:pdfrx/pdfrx.dart';

import '../services/pdf_session.dart';
import 'photo_analysis.dart';
import 'photo_cache.dart';
import 'photo_diagnostics.dart';
import 'photo_geometry.dart';

/// One viewer and one filter pass. Never paste image bitmaps over annotations,
/// highlights, selection, or links; preserve the already composited pixels.
class PhotoPreservingFilter extends StatefulWidget {
  const PhotoPreservingFilter({
    super.key,
    required this.session,
    required this.revision,
    required this.controller,
    required this.enabled,
    required this.selective,
    required this.twoPages,
    required this.strength,
    required this.defaultShader,
    required this.program,
    required this.child,
    this.showDiagnostics = false,
    this.diagnostics,
  });
  final PdfSession session;
  final int revision;
  final PdfViewerController controller;
  final bool enabled, selective, twoPages;
  final double strength;
  final FragmentShader? defaultShader;
  final FragmentProgram? program;
  final Widget child;
  final bool showDiagnostics;
  final PhotoDiagnosticsController? diagnostics;

  @override
  State<PhotoPreservingFilter> createState() => _PhotoPreservingFilterState();
}

class _PhotoPreservingFilterState extends State<PhotoPreservingFilter> {
  static final _disabled = ImageFilter.blur(sigmaX: 0, sigmaY: 0);
  late PhotoAnalysisCache _cache;
  FragmentShader? _shader;

  @override
  void initState() {
    super.initState();
    _createCache();
    _shader = widget.program?.fragmentShader();
  }

  void _createCache() {
    final session = widget.session;
    _cache = PhotoAnalysisCache(
      (page) => session.readLocked((pdf) => analyzePhotos(pdf, page)),
    );
  }

  @override
  void didUpdateWidget(covariant PhotoPreservingFilter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.diagnostics != widget.diagnostics) {
      oldWidget.diagnostics?.publish(null);
    }
    if (!identical(oldWidget.session, widget.session)) {
      _cache.dispose();
      _createCache();
    } else if (oldWidget.revision != widget.revision) {
      _cache.invalidate();
    }
    if (oldWidget.program != widget.program) {
      final oldShader = _shader;
      _shader = widget.program?.fragmentShader();
      // Keep the previous layer's resource alive through this frame.
      WidgetsBinding.instance.addPostFrameCallback((_) => oldShader?.dispose());
    }
  }

  @override
  void dispose() {
    widget.diagnostics?.publish(null);
    _cache.dispose();
    _shader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([widget.controller, _cache]),
    child: widget.child,
    builder: (context, child) {
      final viewer = widget.controller;
      final shader = _shader;
      final active =
          widget.enabled &&
          widget.selective &&
          shader != null &&
          !widget.session.lease.isClosed &&
          viewer.isReady;
      final regions = <Rect>[];
      final diagnosticPages = <PhotoDiagnosticPage>[];
      var omittedPages = 0;
      if ((active || widget.showDiagnostics) &&
          !widget.session.lease.isClosed &&
          viewer.isReady) {
        final visible = viewer.visibleRect;
        final layout = viewer.layout.pageLayouts;
        final pages = visiblePhotoPages(
          layout,
          visible,
          twoPages: widget.twoPages,
        );
        _cache.setVisiblePages(pages);
        omittedPages = (pages.length - _cache.capacity).clamp(0, pages.length);
        for (final number in pages.take(_cache.capacity)) {
          final analysis = _cache.peek(number);
          Rect project(PhotoRegion region) => photoViewportRect(
            region,
            widget.session.lease.document.pages[number - 1],
            layout[number - 1],
            visible,
          );
          final preserved = <PhotoRegion>{};
          if (active) {
            for (final region in analysis?.regions ?? const <PhotoRegion>[]) {
              final rect = project(region);
              if (!rect.isEmpty && regions.length < 16) {
                regions.add(rect);
                preserved.add(region);
              }
            }
          }
          if (widget.showDiagnostics) {
            diagnosticPages.add(
              PhotoDiagnosticPage(number, analysis, [
                for (final candidate in [
                  ...?analysis?.candidates,
                  ...?analysis?.uninspectedForms,
                ])
                  PhotoDiagnosticEntry(
                    pageNumber: number,
                    candidate: candidate,
                    rect: project(candidate.region),
                    preserved: preserved.contains(candidate.region),
                    inactiveReason: !widget.enabled
                        ? 'inversion-off'
                        : !widget.selective
                        ? 'preservation-off'
                        : shader == null
                        ? 'selective-shader-unavailable'
                        : 'visible-region-limit',
                  ),
              ]),
            );
          }
        }
      } else {
        _cache.setVisiblePages(const []);
      }
      if (active) {
        shader.setFloat(2, widget.strength.clamp(0, 1));
        shader.setFloat(3, regions.length.toDouble());
        for (var i = 0; i < 16; i++) {
          final rect = i < regions.length ? regions[i] : Rect.zero;
          shader.setFloat(4 + i * 4, rect.left);
          shader.setFloat(5 + i * 4, rect.top);
          shader.setFloat(6 + i * 4, rect.right);
          shader.setFloat(7 + i * 4, rect.bottom);
        }
      }
      final snapshot = widget.showDiagnostics
          ? PhotoDiagnosticsSnapshot(
              revision: widget.revision,
              pages: diagnosticPages,
              omittedPages: omittedPages,
            )
          : null;
      widget.diagnostics?.publish(snapshot);
      // The child hierarchy stays identical across mode/loading/error changes.
      // No detected regions => use the original shader, byte-for-byte unchanged.
      final effective = active && regions.isNotEmpty
          ? shader
          : widget.defaultShader;
      return Stack(
        fit: StackFit.passthrough,
        children: [
          ImageFiltered(
            enabled: widget.enabled && effective != null,
            imageFilter: widget.enabled && effective != null
                ? ImageFilter.shader(effective)
                : _disabled,
            child: child,
          ),
          if (snapshot != null)
            Positioned.fill(child: PhotoDiagnosticsOverlay(snapshot: snapshot)),
        ],
      );
    },
  );
}
