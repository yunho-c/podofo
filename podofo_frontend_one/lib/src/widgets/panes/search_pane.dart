import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/services.dart' show TextInputAction;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'package:podofo_one/src/providers/document_provider.dart';

class SearchPane extends ConsumerWidget {
  const SearchPane({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final searcher = ref.watch(pdfTextSearcherProvider);
    if (searcher == null) {
      return const Center(child: Text('Open a document to search'));
    }
    return _SearchResults(key: ObjectKey(searcher), searcher: searcher);
  }
}

class _SearchResults extends ConsumerStatefulWidget {
  const _SearchResults({super.key, required this.searcher});
  final PdfTextSearcher searcher;

  @override
  ConsumerState<_SearchResults> createState() => _SearchPaneState();
}

class _SearchPaneState extends ConsumerState<_SearchResults> {
  final _query = TextEditingController();
  final _scroll = ScrollController();
  Timer? _debounce;
  late final PdfTextSearcher _searcher;

  @override
  void initState() {
    super.initState();
    _searcher = widget.searcher;
    _query.addListener(_search);
  }

  void _search() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 180), () {
      if (mounted) _searcher.startTextSearch(_query.text);
    });
    setState(() {});
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.removeListener(_search);
    _query.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _navigate(bool forward) async {
    if (forward) {
      await _searcher.goToNextMatch();
    } else {
      await _searcher.goToPrevMatch();
    }
    if (!mounted || !_scroll.hasClients) return;
    final index = _searcher.currentIndex;
    if (index != null) {
      await _scroll.animateTo(
        (index * 76.0).clamp(0.0, _scroll.position.maxScrollExtent),
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _searcher,
    builder: (context, _) => Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        children: [
          TextField(
            controller: _query,
            autofocus: true,
            placeholder: const Text('Search this document'),
            textInputAction: TextInputAction.search,
          ),
          Row(
            children: [
              Expanded(child: Text('${_searcher.matches.length} matches')),
              IconButton(
                icon: const Icon(Icons.arrow_upward),
                variance: ButtonStyle.ghostIcon(),
                onPressed: _searcher.hasMatches ? () => _navigate(false) : null,
              ),
              IconButton(
                icon: const Icon(Icons.arrow_downward),
                variance: ButtonStyle.ghostIcon(),
                onPressed: _searcher.hasMatches ? () => _navigate(true) : null,
              ),
              IconButton(
                icon: const Icon(Icons.close),
                variance: ButtonStyle.ghostIcon(),
                onPressed: _query.text.isEmpty
                    ? null
                    : () {
                        _query.clear();
                        _debounce?.cancel();
                        _searcher.resetTextSearch();
                      },
              ),
            ],
          ),
          if (_searcher.isSearching)
            LinearProgressIndicator(value: _searcher.searchProgress),
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              itemExtent: 76,
              itemCount: _searcher.matches.length,
              itemBuilder: (context, index) {
                final match = _searcher.matches[index];
                final fullText = match.pageText.fullText;
                final start = math.max(0, match.start - 35);
                final end = math.min(fullText.length, match.end + 60);
                return Button(
                  style: index == _searcher.currentIndex
                      ? ButtonStyle.secondary()
                      : ButtonStyle.ghost(),
                  alignment: Alignment.centerLeft,
                  onPressed: () => _searcher.goToMatchOfIndex(index),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text('Page ${match.pageNumber}').small(),
                      Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: fullText.substring(start, match.start),
                            ),
                            TextSpan(
                              text: match.text,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            TextSpan(text: fullText.substring(match.end, end)),
                          ],
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    ),
  );
}
