import 'package:pdfrx/pdfrx.dart';

import '../services/pdf_session.dart';
import 'narration_sequence.dart';
import 'paper_plan.dart';
import 'source_map.dart';

class PaperReviewRequired implements Exception {
  PaperReviewRequired(this.plan);
  final PaperPagePlan plan;
  @override
  String toString() =>
      plan.issue ?? 'Review page ${plan.page.page} before continuing.';
}

/// Two cached pages; no document-wide audio queue or full-paper extraction.
class PaperSequence implements NarrationSequence {
  PaperSequence(this.session, this.options);
  final PdfSession session;
  PaperReadOptions options;
  final _pages = <int, PaperPagePlan>{};
  final _overrides = <int, PaperOrder>{};
  final _skipped = <int>{};
  int _page = 1, _passage = -1, _epoch = 0;
  bool _closed = false;
  PaperPagePlan? review;
  int get cachedPageCount => _pages.length;
  int get pageNumber => _page;
  int get pageCount => session.lease.document.pages.length;

  Future<PaperPagePlan> preview(
    int number, {
    PaperReadOptions? preferences,
  }) async {
    final selected = preferences ?? options;
    return session.readLocked((pdf) async {
      if (pdf.permissions?.allowsCopying == false) {
        throw StateError('This PDF does not allow text extraction.');
      }
      final page = pdf.pages[number - 1];
      final text = PdfTextSnapshot.fromText(
        await NarrationPdfPage(page).loadStructuredText(),
      );
      final width = page.rotation.index.isOdd ? page.height : page.width;
      return PaperPlanner.plan(text, width, selected);
    });
  }

  Future<PaperPagePlan> _plan(int page, int epoch) async {
    final cached = _pages.remove(page);
    if (cached != null) {
      _pages[page] = cached;
      return cached;
    }
    final override = _overrides[page];
    final plan = await preview(
      page,
      preferences: override == null
          ? options
          : PaperReadOptions(
              order: override,
              stopAtReferences: options.stopAtReferences,
              skipCaptions: options.skipCaptions,
            ),
    );
    if (_closed || epoch != _epoch) throw StateError('Reading was cancelled.');
    _pages[page] = plan;
    while (_pages.length > 2) {
      _pages.remove(_pages.keys.first);
    }
    return plan;
  }

  Future<NarrationPassage?> start({int page = 1, SourceAnchor? anchor}) async {
    if (page < 1 || page > pageCount) {
      throw StateError('The saved page is no longer in this paper.');
    }
    _page = page;
    _passage = -1;
    final epoch = _epoch;
    final plan = await _plan(page, epoch);
    if (anchor != null) {
      if (anchor.textHash != plan.page.textHash ||
          anchor.page != page ||
          anchor.offset < 0 ||
          anchor.offset >= plan.page.text.length) {
        throw StateError(
          'This paper changed since your last reading. Start again from this page.',
        );
      }
      for (var i = 0; i < plan.passages.length; i++) {
        final passage = plan.passages[i];
        final contains = passage.spans.any(
          (s) =>
              s.source.offset <= anchor.offset && s.sourceEnd > anchor.offset,
        );
        if (contains) {
          _passage = i;
          return passage.sliceFrom(passage.offsetOf(anchor)!);
        }
      }
      throw StateError(
        'The saved position is excluded by these reading options. Start again from this page.',
      );
    }
    return move(1);
  }

  @override
  Future<NarrationPassage?> move(int direction) async {
    if (_closed) throw StateError('This paper was closed.');
    final epoch = ++_epoch;
    var page = _page, passage = _passage + direction;
    while (page >= 1 && page <= pageCount) {
      if (_skipped.contains(page)) {
        page += direction;
        passage = direction > 0 ? 0 : -1;
        continue;
      }
      final plan = await _plan(page, epoch);
      if (_closed || epoch != _epoch) {
        throw StateError('Reading was cancelled.');
      }
      if (plan.issue != null) {
        review = plan;
        throw PaperReviewRequired(plan);
      }
      if (direction < 0 && passage == -1 && page != _page) {
        passage = plan.passages.length - 1;
      }
      if (passage >= 0 && passage < plan.passages.length) {
        _page = page;
        _passage = passage;
        review = null;
        return plan.passages[passage];
      }
      if (direction > 0 && plan.endsPaper) return null;
      page += direction;
      passage = direction > 0 ? 0 : -1;
    }
    return null;
  }

  void acceptReview(PaperOrder order) {
    final page = review?.page.page;
    if (page == null) return;
    _overrides[page] = order;
    _pages.remove(page);
    review = null;
  }

  void skipReview() {
    final page = review?.page.page;
    if (page != null) _skipped.add(page);
    review = null;
  }

  @override
  void cancelPending() {
    _epoch++;
  }

  @override
  void close() {
    _closed = true;
    cancelPending();
    _pages.clear();
  }
}
