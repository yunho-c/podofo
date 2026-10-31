import 'dart:ui';

import 'package:pdfrx/pdfrx.dart';

import '../narration/source_map.dart';
import '../analysis/preview_layout_repository.dart';
import 'link_target.dart';
import 'link_target_resolver.dart';
import 'preview_geometry.dart';

class PreviewTextPage {
  PreviewTextPage(this.snapshot, List<Rect> boxes)
    : boxes = List.unmodifiable(boxes);
  final PdfTextSnapshot snapshot;
  final List<Rect> boxes;
  // UTF-16 plus both raw and displayed four-double rectangles; not total heap.
  int get accountedBytes =>
      snapshot.text.length * 2 + (snapshot.boxes.length + boxes.length) * 32;
}

class PreviewTextSpan {
  PreviewTextSpan(this.start, this.end, this.text, List<Rect> boxes)
    : boxes = List.unmodifiable(boxes);
  final int start, end;
  final String text;
  final List<Rect> boxes;
}

class LinkSourceText {
  LinkSourceText(
    List<PreviewTextSpan> spans,
    this.before,
    this.after,
    this.truncated,
  ) : spans = List.unmodifiable(spans);
  final List<PreviewTextSpan> spans;
  final String before, after;
  final bool truncated;
}

LinkSourceText sourceLinkText(PreviewTextPage page, List<Rect> links) {
  final text = page.snapshot.text;
  final hits = <int>[];
  var truncated = false;
  for (var i = 0; i < page.boxes.length; i++) {
    if (!page.boxes[i].isEmpty && links.any((r) => r.overlaps(page.boxes[i]))) {
      // PDFium may give spaces/newlines empty boxes. Retain whitespace between
      // selected glyphs so author/year labels preserve their original text.
      if (hits.isNotEmpty &&
          hits.last + 1 < i &&
          text.substring(hits.last + 1, i).trim().isEmpty) {
        final gapStart = hits.last + 1;
        for (var j = gapStart; j < i && hits.length < 2048; j++) {
          hits.add(j);
        }
      }
      if (hits.length == 2048) {
        truncated = true;
        break;
      }
      hits.add(i);
    }
  }
  bool low(int i) =>
      i < text.length &&
      text.codeUnitAt(i) >= 0xdc00 &&
      text.codeUnitAt(i) <= 0xdfff;
  // Never return half of a surrogate pair at the extraction budget boundary.
  if (truncated && hits.isNotEmpty && low(hits.last + 1)) hits.removeLast();
  final spans = <PreviewTextSpan>[];
  for (var i = 0; i < hits.length;) {
    final start = hits[i];
    var end = start + 1;
    while (++i < hits.length && hits[i] == end) {
      end++;
    }
    spans.add(
      PreviewTextSpan(
        start,
        end,
        text.substring(start, end),
        page.boxes.sublist(start, end),
      ),
    );
  }
  if (spans.isEmpty) return LinkSourceText([], '', '', truncated);
  final first = spans.first.start, last = spans.last.end;
  var before = (first - 256).clamp(0, text.length),
      after = (last + 256).clamp(0, text.length);
  if (low(before)) before++;
  if (low(after)) after--;
  return LinkSourceText(
    spans,
    text.substring(before, first),
    text.substring(last, after),
    truncated,
  );
}

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
    PreviewLayoutRepository? repository,
  ) async {
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
      layout = await repository?.read(request, isCurrent: valid);
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
      ),
    );
  }
}
