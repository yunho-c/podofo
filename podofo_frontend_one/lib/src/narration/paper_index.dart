import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'paper_plan.dart';
import 'source_map.dart';

enum PaperIndexStatus { idle, indexing, cancelled, scanned, closed }

enum PaperIndexPageStatus { readable, skipped, reviewRequired, failed }

/// Compact identity and speech statistics; no text, geometry or audio retention.
@immutable
class IndexedPaperPassage {
  const IndexedPaperPassage._({
    required this.revision,
    required this.optionsKey,
    required this.ordinal,
    required this.anchor,
    required this.spokenTextHash,
    required this.utf16Length,
    required this.scalarCount,
    required this.wordCount,
    required this.punctuationCount,
  });
  factory IndexedPaperPassage.fromPassage(
    NarrationPassage passage, {
    required int revision,
    required String optionsKey,
    required int ordinal,
  }) {
    final source = passage.anchorAt(0)!;
    return IndexedPaperPassage._(
      revision: revision,
      optionsKey: optionsKey,
      ordinal: ordinal,
      // Drop the bounded context strings too: reconstruct text from the page.
      anchor: SourceAnchor(source.page, source.offset, source.textHash),
      spokenTextHash: sha256.convert(utf8.encode(passage.text)).toString(),
      utf16Length: passage.text.length,
      scalarCount: passage.text.runes.length,
      wordCount: _words.allMatches(passage.text).length,
      punctuationCount: _punctuation.allMatches(passage.text).length,
    );
  }
  static final _words = RegExp(r'[\p{L}\p{M}\p{N}]+', unicode: true);
  static final _punctuation = RegExp(r'\p{P}', unicode: true);
  final int revision,
      ordinal,
      utf16Length,
      scalarCount,
      wordCount,
      punctuationCount;
  final String optionsKey, spokenTextHash;
  final SourceAnchor anchor;
  int get page => anchor.page;
  String get id =>
      '$revision:$optionsKey:$page:${anchor.textHash}:$ordinal:$spokenTextHash';
}

@immutable
class IndexedPaperPage {
  IndexedPaperPage({
    required this.page,
    required this.status,
    this.textHash,
    this.issue,
    this.endsPaper = false,
    Iterable<IndexedPaperPassage> passages = const [],
  }) : passages = List.unmodifiable(passages);
  final int page;
  final PaperIndexPageStatus status;
  final String? textHash, issue;
  final bool endsPaper;
  final List<IndexedPaperPassage> passages;
  bool get unresolved =>
      status == PaperIndexPageStatus.reviewRequired ||
      status == PaperIndexPageStatus.failed;
}

@immutable
class PaperIndexSnapshot {
  PaperIndexSnapshot({
    required this.revision,
    required this.status,
    required this.pageCount,
    required this.scopeEndPage,
    required Iterable<IndexedPaperPage> pages,
  }) : pages = List.unmodifiable(pages);
  final int revision, pageCount, scopeEndPage;
  final PaperIndexStatus status;

  /// Document order, bounded by the earliest known reference stop. Missing
  /// earlier pages or review issues make that scope provisional.
  final List<IndexedPaperPage> pages;
  int get processedPageCount => pages.length;
  int get readablePassageCount =>
      pages.fold(0, (n, p) => n + p.passages.length);
  Iterable<IndexedPaperPage> get unresolvedPages =>
      pages.where((p) => p.unresolved);
  Iterable<IndexedPaperPassage> get passages => pages.expand((p) => p.passages);
  bool get scanFinished =>
      status != PaperIndexStatus.closed && pages.length == scopeEndPage;
  bool get fullyResolved => scanFinished && unresolvedPages.isEmpty;
}

/// Session-local metadata. Work cancellation is separate from plan revision.
class PaperIndex extends ChangeNotifier {
  PaperIndex(this.pageCount);
  final int pageCount;
  final _pages = <int, IndexedPaperPage>{};
  int _revision = 0;
  PaperIndexStatus _status = PaperIndexStatus.idle;
  PaperIndexSnapshot? _snapshot;
  bool get _closed => _status == PaperIndexStatus.closed;
  int get revision => _revision;
  int get retainedPageCount => _pages.length;
  IndexedPaperPage? page(int number) => _pages[number];
  int get scopeEndPage => _pages.values
      .where((p) => p.endsPaper)
      .fold(pageCount, (end, p) => p.page < end ? p.page : end);
  PaperIndexSnapshot get snapshot {
    if (_snapshot != null) return _snapshot!;
    final end = scopeEndPage;
    return _snapshot = PaperIndexSnapshot(
      revision: _revision,
      status: _status,
      pageCount: pageCount,
      scopeEndPage: end,
      pages: (_pages.values.where((p) => p.page <= end).toList()
        ..sort((a, b) => a.page.compareTo(b.page))),
    );
  }

  void _publish() {
    _snapshot = null;
    notifyListeners();
  }

  void begin() {
    if (_closed) return;
    _pages.removeWhere((_, p) => p.status == PaperIndexPageStatus.failed);
    _status = PaperIndexStatus.indexing;
    _publish();
  }

  void finish() {
    if (_closed) return;
    _status = PaperIndexStatus.scanned;
    _publish();
  }

  void record(PaperPagePlan plan, PaperReadOptions options) {
    if (_closed) return;
    _pages[plan.page.page] = IndexedPaperPage(
      page: plan.page.page,
      textHash: plan.page.textHash,
      issue: plan.issue,
      status: plan.issue == null
          ? PaperIndexPageStatus.readable
          : PaperIndexPageStatus.reviewRequired,
      endsPaper: plan.endsPaper,
      passages: [
        for (var i = 0; i < plan.passages.length; i++)
          IndexedPaperPassage.fromPassage(
            plan.passages[i],
            revision: _revision,
            optionsKey: options.key,
            ordinal: i,
          ),
      ],
    );
    _publish();
  }

  void fail(int page, Object error) {
    if (_closed) return;
    final message = error.toString();
    _pages[page] = IndexedPaperPage(
      page: page,
      status: PaperIndexPageStatus.failed,
      issue: message.length <= 512 ? message : message.substring(0, 512),
    );
    _publish();
  }

  void skip(int page) {
    if (_closed) return;
    _pages[page] = IndexedPaperPage(
      page: page,
      status: PaperIndexPageStatus.skipped,
    );
    _publish();
  }

  void invalidate(int page) {
    if (_closed) return;
    _pages.remove(page);
    _publish();
  }

  void cancel() {
    if (_closed) return;
    _status = PaperIndexStatus.cancelled;
    _publish();
  }

  void reset() {
    if (_closed) return;
    _revision++;
    _pages.clear();
    _status = PaperIndexStatus.idle;
    _publish();
  }

  void close() {
    if (_closed) return;
    _pages.clear();
    _status = PaperIndexStatus.closed;
    _publish();
    dispose();
  }
}
