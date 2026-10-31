import 'package:pdfrx/pdfrx.dart';

import '../narration/source_map.dart';
import '../analysis/preview_layout_repository.dart';
import 'link_target.dart';
import 'preview_text.dart';
import 'link_target_resolver.dart';
import 'preview_geometry.dart';

export 'preview_text.dart';

class PreparedLinkPreview {
  const PreparedLinkPreview(
    this.destination,
    this.source,
    this.targetText,
    this.layout,
    this.resolution,
  );
  final PreviewDestination? destination;
  final LinkSourceText? source;
  final PreviewTextPage? targetText;
  final PreviewLayoutEvidence? layout;
  final ResolvedLinkTarget resolution;
}

/// Owned text cache and preparation stages. The worker serializes consumers.
class PdfLinkContext {
  PdfLinkContext({this.maxPages = 8, this.maxBytes = 4 * 1024 * 1024});
  final int maxPages, maxBytes;
  final _pages = <Object, PreviewTextPage>{};
  int bytes = 0;
  int get length => _pages.length;
  void clear() {
    _pages.clear();
    bytes = 0;
  }

  Future<PreviewTextPage?> text(
    LinkPreviewRequest request,
    int number,
    bool Function() current,
  ) async {
    if (!request.isCurrent || !current()) return null;
    final key = (request.session, request.revision, number);
    final cached = _pages.remove(key);
    if (cached != null) {
      _pages[key] = cached;
      return cached;
    }
    final result = await request.session.readLocked((pdf) async {
      if (!request.isCurrent ||
          !current() ||
          pdf.permissions?.allowsCopying == false ||
          number < 1 ||
          number > pdf.pages.length) {
        return null;
      }
      final page = pdf.pages[number - 1];
      final raw = await page.loadText();
      if (raw == null ||
          raw.fullText.length > 200000 ||
          !request.isCurrent ||
          !current()) {
        return null;
      }
      final snapshot = PdfTextSnapshot(
        page: number,
        text: raw.fullText,
        boxes: raw.charRects,
      );
      final result = PreviewTextPage(
        snapshot,
        snapshot.boxes.map((b) => b.toRect(page: page)).toList(),
      );
      return result.accountedBytes > maxBytes ? null : result;
    });
    if (result == null || !request.isCurrent || !current()) return null;
    if (maxPages > 0) {
      _pages[key] = result;
      bytes += result.accountedBytes;
      while (length > maxPages || bytes > maxBytes) {
        bytes -= _pages.remove(_pages.keys.first)!.accountedBytes;
      }
    }
    return result;
  }

  Future<PreparedLinkPreview?> prepare(
    LinkPreviewRequest request,
    bool Function() current,
    PreviewLayoutRepository? repository, {
    PreviewCancellation? cancellation,
  }) async {
    bool valid() => request.isCurrent && current();
    if (!valid()) return null;
    final geometry = await request.session.readLocked((pdf) async {
      if (!valid() ||
          request.destination.pageNumber < 1 ||
          request.destination.pageNumber > pdf.pages.length ||
          request.sourcePage < 1 ||
          request.sourcePage > pdf.pages.length) {
        return null;
      }
      final bounds = await previewPageBounds(
        pdf,
        request.destination.pageNumber,
      );
      if (!valid() || bounds == null) return null;
      return (
        destination: normalizePreviewDestination(
          pdf.pages[request.destination.pageNumber - 1],
          request.destination,
          bounds,
        ),
        sourceRects: request.sourceRects
            .map((r) => r.toRect(page: pdf.pages[request.sourcePage - 1]))
            .toList(),
      );
    });
    if (!valid()) return null;
    LinkSourceText? source;
    PreviewTextPage? target;
    PreviewLayoutEvidence? layout;
    // Missing/excessive/restricted text does not invalidate an explicit area.
    try {
      final page = await text(request, request.sourcePage, valid);
      if (page != null && geometry != null) {
        source = sourceLinkText(page, geometry.sourceRects);
      }
      if (!valid()) return null;
      target = await text(request, request.destination.pageNumber, valid);
    } catch (_) {
      /* Contextual fallback remains available. */
    }
    if (!valid()) return null;
    try {
      // An explicit area already resolves without a model. Missing/restricted
      // text cannot establish identity, so it must not trigger automatic work.
      if (geometry?.destination != null &&
          geometry!.destination!.area == null &&
          source != null &&
          source.spans.isNotEmpty &&
          !source.truncated &&
          target != null) {
        layout = await repository?.read(
          request,
          isCurrent: valid,
          cancellation: cancellation,
        );
      }
    } catch (_) {
      /* Cache miss. */
    }
    if (!valid()) return null;
    final destination = geometry?.destination;
    if (layout != null &&
        destination != null &&
        (layout.page.page.space.width != destination.pageSize.width ||
            layout.page.page.space.height != destination.pageSize.height)) {
      layout = null;
    }
    return PreparedLinkPreview(
      destination,
      source,
      target,
      layout,
      const LinkTargetResolver().resolve(
        destination,
        evidenceIdentity: layout?.identity,
        source: source,
        text: target,
        layout: layout,
      ),
    );
  }
}
