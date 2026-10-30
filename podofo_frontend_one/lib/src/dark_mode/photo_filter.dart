import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:pdfrx/pdfrx.dart';

import '../services/pdf_session.dart';
import 'photo_analysis.dart';
import 'photo_cache.dart';
import 'photo_diagnostics.dart';
import 'photo_geometry.dart';
import 'photo_mask.dart';
import 'photo_overrides.dart';
import 'photo_override_overlay.dart';

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
  final _masks = PhotoMaskCache();
  List<Rect>? _maskLayout;

  @override
  void initState() {
    super.initState();
    _createCache();
    _shader = widget.program?.fragmentShader();
  }

  void _createCache() {
    final session = widget.session;
    _cache = PhotoAnalysisCache((page, previous, priority) {
      final revision = widget.revision;
      return session.readLocked((pdf) {
        if (session.revision != revision) {
          throw StateError('Document revision changed');
        }
        return analyzePhotoBatch(
          pdf,
          page,
          previous: previous,
          priority: priority,
        );
      });
    });
  }

  @override
  void didUpdateWidget(covariant PhotoPreservingFilter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.diagnostics != widget.diagnostics) {
      oldWidget.diagnostics?.publish(null);
    }
    if (!identical(oldWidget.session, widget.session)) {
      _cache.dispose();
      _masks.invalidate();
      _maskLayout = null;
      _createCache();
    } else if (oldWidget.revision != widget.revision) {
      _cache.invalidate();
      _masks.invalidate();
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
    _masks.dispose();
    _shader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([
      widget.controller,
      _cache,
      _masks,
      if (!widget.session.lease.isClosed) widget.session.photoOverrides,
    ]),
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
      final priorities = <int, List<String>>{};
      final diagnosticPages = <PhotoDiagnosticPage>[];
      final overrideEntries = <PhotoOverrideEntry>[];
      final overrides = widget.session.photoOverrides;
      var omittedPages = 0;
      if ((active || widget.showDiagnostics) &&
          !widget.session.lease.isClosed &&
          viewer.isReady) {
        final visible = viewer.visibleRect;
        final layout = viewer.layout.pageLayouts;
        if (!identical(_maskLayout, layout)) {
          if (_maskLayout != null && !listEquals(_maskLayout, layout)) {
            _masks.invalidate();
          }
          _maskLayout = layout;
        }
        final pages = visiblePhotoPages(
          layout,
          visible,
          twoPages: widget.twoPages,
        );
        omittedPages = (pages.length - _cache.capacity).clamp(0, pages.length);
        for (final number in pages.take(_cache.capacity)) {
          final analysis = _cache.peek(number);
          final page = widget.session.lease.document.pages[number - 1];
          final targets = {
            for (final c in analysis?.candidates ?? const <PhotoCandidate>[])
              c: PhotoOverrides.target(page, c),
          };
          Rect project(PhotoRegion region) => photoViewportRect(
            region,
            widget.session.lease.document.pages[number - 1],
            layout[number - 1],
            visible,
          );
          Rect documentRect(PhotoRegion region) => photoDocumentRect(
            region,
            widget.session.lease.document.pages[number - 1],
            layout[number - 1],
          );
          final pending = [
            for (final c in analysis?.candidates ?? const <PhotoCandidate>[])
              if (c.reason == 'pending' && !project(c.region).isEmpty) c,
          ];
          double visibleArea(PhotoCandidate c) {
            final r = project(c.region);
            return r.width * r.height;
          }

          pending.sort((a, b) => visibleArea(b).compareTo(visibleArea(a)));
          priorities[number] = pending.map((c) => c.objectId).toList();
          if (active) {
            for (final candidate
                in analysis?.candidates ?? const <PhotoCandidate>[]) {
              final target = targets[candidate];
              final manual = overrides.decision(target);
              final automatic = candidate.reason == 'likely-photo';
              if (manual ?? automatic) {
                final rect = documentRect(candidate.region);
                if (!rect.isEmpty) regions.add(rect);
              }
              final rect = project(candidate.region);
              if (target != null && !rect.isEmpty) {
                overrideEntries.add(
                  PhotoOverrideEntry(
                    target: target,
                    rect: rect,
                    automatic: automatic,
                    override: manual,
                  ),
                );
              }
            }
          }
          if (widget.showDiagnostics) {
            diagnosticPages.add(
              PhotoDiagnosticPage(number, analysis, [
                for (final candidate
                    in analysis?.candidates.take(128) ??
                        const <PhotoCandidate>[])
                  PhotoDiagnosticEntry(
                    pageNumber: number,
                    candidate: candidate,
                    override: overrides.decision(targets[candidate]),
                    rect: project(candidate.region),
                    preserved:
                        active &&
                        !project(candidate.region).isEmpty &&
                        (_masks.current?.rectangles.contains(
                              documentRect(candidate.region),
                            ) ??
                            false),
                    inactiveReason: !widget.enabled
                        ? 'inversion-off'
                        : !widget.selective
                        ? 'preservation-off'
                        : shader == null
                        ? 'selective-shader-unavailable'
                        : _masks.failed
                        ? 'mask-unavailable'
                        : 'mask-pending',
                  ),
              ]),
            );
          }
        }
        _cache.setVisiblePages(pages, priorities: priorities);
        if (active && pages.isNotEmpty) {
          final bounds = pages
              .take(_cache.capacity)
              .map((p) => layout[p - 1])
              .reduce((a, b) => a.expandToInclude(b));
          _masks.request(bounds, regions);
        }
      } else {
        _cache.setVisiblePages(const []);
      }
      final mask = _masks.current;
      if (active && mask != null) {
        mask.configure(shader, widget.strength, viewer.visibleRect);
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
      final effective = active && mask != null && mask.rectangles.isNotEmpty
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
          Positioned.fill(
            child: PhotoOverrideOverlay(
              enabled: active,
              entries: overrideEntries,
              controller: viewer,
              error: overrides.error,
              onToggle: (entry) {
                if (!widget.session.lease.isClosed) {
                  overrides.toggle(entry.target, automatic: entry.automatic);
                }
              },
            ),
          ),
        ],
      );
    },
  );
}
