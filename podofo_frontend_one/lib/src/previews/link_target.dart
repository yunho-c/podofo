import 'dart:ui';

import 'package:pdfrx/pdfrx.dart';

import '../services/pdf_session.dart';

const linkResolverVersion = 2;
const semanticPreviewMaxSize = Size(480, 360);

/// Consumer cancellation detaches subscriptions without stealing shared work.
class PreviewCancellation {
  bool _cancelled = false;
  final _listeners = <void Function()>{};
  bool get isCancelled => _cancelled;
  void Function() onCancel(void Function() listener) {
    if (_cancelled) {
      listener();
    } else {
      _listeners.add(listener);
    }
    return () => _listeners.remove(listener);
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    final listeners = _listeners.toList();
    _listeners.clear();
    for (final listener in listeners) {
      listener();
    }
  }
}

/// Immutable identity captured before any asynchronous preparation.
class LinkPreviewRequest {
  LinkPreviewRequest({
    required this.session,
    required this.sourcePage,
    required this.annotationIndex,
    required List<PdfRect> sourceRects,
    required PdfDest destination,
    required this.pixelRatio,
    this.maxSize = semanticPreviewMaxSize,
  }) : revision = session.revision,
       sourceRects = List.unmodifiable(sourceRects),
       destination = destination.compact();
  final PdfSession session;
  final int revision, sourcePage, annotationIndex;
  final List<PdfRect> sourceRects;
  final PdfDest destination;
  final double pixelRatio;

  /// Logical raster envelope; the compositor also applies its hard pixel cap.
  final Size maxSize;
  bool get isCurrent => !session.lease.isClosed && session.revision == revision;
  Object get identity => (
    session,
    revision,
    sourcePage,
    annotationIndex,
    sourceRects
        .map((r) => '${r.left},${r.top},${r.right},${r.bottom}')
        .join(';'),
    destination.pageNumber,
    destination.command,
    destination.params?.join(','),
  );
}

/// Nullable axes remain unknown after rotation; centers are only for rendering.
class PreviewDestination {
  const PreviewDestination({
    required this.page,
    required this.pageSize,
    this.x,
    this.y,
    this.area,
  });
  final int page;
  final Size pageSize;
  final double? x, y;
  final Rect? area;
}

enum LinkTargetKind { explicitArea, citation, figure, table, equation, section }

enum LinkTargetTier { explicitArea, matchedIdentity, unresolved }

class ResolvedLinkTarget {
  ResolvedLinkTarget({
    required this.tier,
    required this.reason,
    this.kind,
    this.label,
    this.evidenceIdentity,
    List<({int page, Rect bounds})> parts = const [],
  }) : parts = List.unmodifiable(parts);
  final LinkTargetTier tier;
  final LinkTargetKind? kind;
  final String reason;
  final String? label;
  final Object? evidenceIdentity;
  final List<({int page, Rect bounds})> parts;
  Object cacheKey(LinkPreviewRequest request) => (
    request.identity,
    linkResolverVersion,
    evidenceIdentity,
    tier,
    kind,
    parts
        .map(
          (p) =>
              '${p.page}:${p.bounds.left},${p.bounds.top},${p.bounds.right},${p.bounds.bottom}',
        )
        .join(';'),
    request.pixelRatio,
    request.maxSize.width,
    request.maxSize.height,
  );
}
