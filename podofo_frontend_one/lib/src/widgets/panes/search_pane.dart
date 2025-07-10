import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:synchronized/extension.dart';

import 'package:podofo_one/src/providers/providers.dart';

class SearchPane extends ConsumerStatefulWidget {
  const SearchPane({super.key});

  @override
  ConsumerState<SearchPane> createState() => _SearchPaneState();
}

class _SearchPaneState extends ConsumerState<SearchPane> {
  final _searchTextController = TextEditingController();
  late final PdfTextSearcher _textSearcher;

  @override
  void initState() {
    super.initState();
    _textSearcher = ref.read(pdfTextSearcherProvider);
    _textSearcher.addListener(_searchResultUpdated);
    _searchTextController.addListener(_searchTextUpdated);
  }

  @override
  void dispose() {
    _textSearcher.removeListener(_searchResultUpdated);
    _searchTextController.removeListener(_searchTextUpdated);
    _searchTextController.dispose();
    super.dispose();
  }

  void _searchTextUpdated() {
    _textSearcher.startTextSearch(_searchTextController.text);
  }

  void _searchResultUpdated() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return TextSearchView(
      textSearcher: _textSearcher,
      searchTextController: _searchTextController,
    );
  }
}

class TextSearchView extends StatefulWidget {
  const TextSearchView({
    required this.textSearcher,
    required this.searchTextController,
    super.key,
  });

  final PdfTextSearcher textSearcher;
  final TextEditingController searchTextController;

  @override
  State<TextSearchView> createState() => _TextSearchViewState();
}

class _TextSearchViewState extends State<TextSearchView> {
  final focusNode = FocusNode();
  late final pageTextStore = PdfPageTextCache(
    textSearcher: widget.textSearcher,
  );
  final scrollController = ScrollController();
  int? _currentSearchSession;
  final _matchIndexToListIndex = <int>[];
  final _listIndexToMatchIndex = <int>[];

  @override
  void initState() {
    super.initState();
    widget.textSearcher.addListener(_searchResultUpdated);
    _searchResultUpdated();
  }

  @override
  void dispose() {
    scrollController.dispose();
    widget.textSearcher.removeListener(_searchResultUpdated);
    focusNode.dispose();
    super.dispose();
  }

  void _searchResultUpdated() {
    if (_currentSearchSession != widget.textSearcher.searchSession) {
      _currentSearchSession = widget.textSearcher.searchSession;
      _matchIndexToListIndex.clear();
      _listIndexToMatchIndex.clear();
    }
    for (
      int i = _matchIndexToListIndex.length;
      i < widget.textSearcher.matches.length;
      i++
    ) {
      if (i == 0 ||
          widget.textSearcher.matches[i - 1].pageNumber !=
              widget.textSearcher.matches[i].pageNumber) {
        _listIndexToMatchIndex.add(-widget.textSearcher.matches[i].pageNumber);
      }
      _matchIndexToListIndex.add(_listIndexToMatchIndex.length);
      _listIndexToMatchIndex.add(i);
    }

    if (mounted) setState(() {});
  }

  static const double itemHeight = 60;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Column(
        children: [
          widget.textSearcher.isSearching
              ? LinearProgressIndicator(
                  value: widget.textSearcher.searchProgress,
                  minHeight: 4,
                )
              : const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: TextField(
                  autofocus: true,
                  focusNode: focusNode,
                  controller: widget.searchTextController,
                  textInputAction: TextInputAction.search,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.arrow_downward),
                onPressed: widget.textSearcher.hasMatches
                    ? () async {
                        await widget.textSearcher.goToNextMatch();
                        _conditionScrollPosition();
                      }
                    : null,
                variance: ButtonVariance.ghost,
                size: ButtonSize.small,
              ),
              IconButton(
                icon: const Icon(Icons.arrow_upward),
                onPressed: widget.textSearcher.hasMatches
                    ? () async {
                        await widget.textSearcher.goToPrevMatch();
                        _conditionScrollPosition();
                      }
                    : null,
                variance: ButtonVariance.ghost,
                size: ButtonSize.small,
              ),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: widget.searchTextController.text.isNotEmpty
                    ? () {
                        widget.searchTextController.text = '';
                        widget.textSearcher.resetTextSearch();
                        focusNode.requestFocus();
                      }
                    : null,
                variance: ButtonVariance.ghost,
                size: ButtonSize.small,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView.builder(
              key: Key(widget.searchTextController.text),
              controller: scrollController,
              itemCount: _listIndexToMatchIndex.length,
              itemBuilder: (context, index) {
                final matchIndex = _listIndexToMatchIndex[index];
                if (matchIndex >= 0 &&
                    matchIndex < widget.textSearcher.matches.length) {
                  final match = widget.textSearcher.matches[matchIndex];
                  return SearchResultTile(
                    key: ValueKey(index),
                    match: match,
                    onTap: () async {
                      await widget.textSearcher.goToMatchOfIndex(matchIndex);
                      if (mounted) setState(() {});
                    },
                    pageTextStore: pageTextStore,
                    height: itemHeight,
                    isCurrent: matchIndex == widget.textSearcher.currentIndex,
                  );
                } else {
                  return Container(
                    height: 20,
                    alignment: Alignment.bottomLeft,
                    margin: EdgeInsets.only(bottom: 6.0),
                    child: Text(
                      'Page ${-matchIndex}',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  );
                }
              },
            ),
          ),
        ],
      ),
    );
  }

  void _conditionScrollPosition() {
    if (widget.textSearcher.currentIndex == null) return;
    final pos = scrollController.position;
    final newPos =
        itemHeight * _matchIndexToListIndex[widget.textSearcher.currentIndex!];
    if (newPos + itemHeight > pos.pixels + pos.viewportDimension) {
      scrollController.animateTo(
        newPos + itemHeight - pos.viewportDimension,
        duration: const Duration(milliseconds: 300),
        curve: Curves.decelerate,
      );
    } else if (newPos < pos.pixels) {
      scrollController.animateTo(
        newPos,
        duration: const Duration(milliseconds: 300),
        curve: Curves.decelerate,
      );
    }
    if (mounted) setState(() {});
  }
}

class SearchResultTile extends StatefulWidget {
  const SearchResultTile({
    required this.match,
    required this.onTap,
    required this.pageTextStore,
    required this.height,
    required this.isCurrent,
    super.key,
  });

  final PdfTextRangeWithFragments match;
  final void Function() onTap;
  final PdfPageTextCache pageTextStore;
  final double height;
  final bool isCurrent;

  @override
  State<SearchResultTile> createState() => _SearchResultTileState();
}

class _SearchResultTileState extends State<SearchResultTile> {
  PdfPageText? pageText;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant SearchResultTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.match.pageNumber != widget.match.pageNumber) {
      _load();
    }
  }

  void _release() {
    if (pageText != null) {
      widget.pageTextStore.releaseText(pageText!.pageNumber);
    }
  }

  Future<void> _load() async {
    _release();
    pageText = await widget.pageTextStore.loadText(widget.match.pageNumber);
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = Text.rich(createTextSpanForMatch(pageText, widget.match));

    return SizedBox(
      height: widget.height,
      // child: Material(
      // color: widget.isCurrent ? Theme.of(context).hoverColor : null,
      child: Button(
        style: ButtonVariance.ghost,
        onPressed: () => widget.onTap(),
        child: Container(
          decoration: const BoxDecoration(
            // border: Border(bottom: BorderSide(color: Colors.black, width: 0.5)),
          ),
          padding: const EdgeInsets.all(3),
          child: text,
          // ),
        ),
      ),
    );
  }

  TextSpan createTextSpanForMatch(
    PdfPageText? pageText,
    PdfTextRangeWithFragments match, {
    TextStyle? style,
  }) {
    style ??= const TextStyle(fontSize: 14);
    if (pageText == null) {
      return TextSpan(
        text: match.fragments.map((f) => f.text).join(),
        style: style,
      );
    }
    final fullText = pageText.fullText;
    int first = 0;
    for (int i = match.fragments.first.index - 1; i >= 0;) {
      if (fullText[i] == '\n') {
        first = i + 1;
        break;
      }
      i--;
    }
    int last = fullText.length;
    for (int i = match.fragments.last.end; i < fullText.length; i++) {
      if (fullText[i] == '\n') {
        last = i;
        break;
      }
    }

    final header = fullText.substring(
      first,
      match.fragments.first.index + match.start,
    );
    final body = fullText.substring(
      match.fragments.first.index + match.start,
      match.fragments.last.index + match.end,
    );
    final footer = fullText.substring(
      match.fragments.last.index + match.end,
      last,
    );

    return TextSpan(
      children: [
        TextSpan(text: header),
        TextSpan(
          text: body,
          // style: const TextStyle(backgroundColor: Colors.yellow),
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        TextSpan(text: footer),
      ],
      style: style,
    );
  }
}

class PdfPageTextCache {
  final PdfTextSearcher textSearcher;
  PdfPageTextCache({required this.textSearcher});

  final _pageTextRefs = <int, _PdfPageTextRefCount>{};

  Future<PdfPageText> loadText(int pageNumber) async {
    final ref = _pageTextRefs[pageNumber];
    if (ref != null) {
      ref.refCount++;
      return ref.pageText;
    }
    return await synchronized(() async {
      var ref = _pageTextRefs[pageNumber];
      if (ref == null) {
        final pageText = await textSearcher.loadText(pageNumber: pageNumber);
        ref = _pageTextRefs[pageNumber] = _PdfPageTextRefCount(pageText!);
      }
      ref.refCount++;
      return ref.pageText;
    });
  }

  void releaseText(int pageNumber) {
    final ref = _pageTextRefs[pageNumber];
    if (ref != null) {
      ref.refCount--;
      if (ref.refCount == 0) {
        _pageTextRefs.remove(pageNumber);
      }
    }
  }
}

class _PdfPageTextRefCount {
  _PdfPageTextRefCount(this.pageText);
  final PdfPageText pageText;
  int refCount = 0;
}
