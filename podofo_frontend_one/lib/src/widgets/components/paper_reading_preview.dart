import 'package:flutter/material.dart' as m;

import '../../narration/paper_plan.dart';
import '../../narration/paper_sequence.dart';
import '../../narration/source_map.dart';

class PaperReadingChoice {
  const PaperReadingChoice(this.page, this.options, this.anchor);
  final int page;
  final PaperReadOptions options;
  final SourceAnchor? anchor;
}

class PaperReadingPreview extends m.StatefulWidget {
  const PaperReadingPreview({
    super.key,
    required this.sequence,
    required this.page,
    this.anchor,
    this.savedPlanVersion,
  });
  final PaperSequence sequence;
  final int page;
  final SourceAnchor? anchor;
  final int? savedPlanVersion;
  @override
  m.State<PaperReadingPreview> createState() => _PaperReadingPreviewState();
}

class _PaperReadingPreviewState extends m.State<PaperReadingPreview> {
  late int _page = widget.page;
  late PaperReadOptions _options = widget.sequence.options;
  late Future<PaperPagePlan> _preview = widget.sequence.preview(_page);
  void _refresh({
    int? page,
    bool? references,
    bool? captions,
    bool? runningMatter,
  }) {
    setState(() {
      _page = page ?? _page;
      _options = PaperReadOptions(
        stopAtReferences: references ?? _options.stopAtReferences,
        skipCaptions: captions ?? _options.skipCaptions,
        skipRunningMatter: runningMatter ?? _options.skipRunningMatter,
      );
      _preview = widget.sequence.preview(_page, preferences: _options);
    });
  }

  @override
  m.Widget build(m.BuildContext context) => m.AlertDialog(
    title: const m.Text('Review reading order'),
    content: m.SizedBox(
      width: 620,
      height: 410,
      child: m.Column(
        children: [
          m.Row(
            children: [
              m.IconButton(
                tooltip: 'Previous preview page',
                onPressed: _page > 1 ? () => _refresh(page: _page - 1) : null,
                icon: const m.Icon(m.Icons.chevron_left),
              ),
              m.Text('Page $_page of ${widget.sequence.pageCount}'),
              m.IconButton(
                tooltip: 'Next preview page',
                onPressed: _page < widget.sequence.pageCount
                    ? () => _refresh(page: _page + 1)
                    : null,
                icon: const m.Icon(m.Icons.chevron_right),
              ),
            ],
          ),
          m.CheckboxListTile(
            dense: true,
            contentPadding: m.EdgeInsets.zero,
            title: const m.Text('Stop before References or Bibliography'),
            value: _options.stopAtReferences,
            onChanged: (value) => _refresh(references: value),
          ),
          m.CheckboxListTile(
            dense: true,
            contentPadding: m.EdgeInsets.zero,
            title: const m.Text(
              'Skip repeated headers, footers and page numbers',
            ),
            value: _options.skipRunningMatter,
            onChanged: (value) => _refresh(runningMatter: value),
          ),
          m.CheckboxListTile(
            dense: true,
            contentPadding: m.EdgeInsets.zero,
            title: const m.Text('Skip figure and table captions'),
            value: _options.skipCaptions,
            onChanged: (value) => _refresh(captions: value),
          ),
          const m.Text(
            'Reading follows PDF text order. Check the preview; equations, tables, or an incorrect PDF order may need selected text.',
          ),
          const m.SizedBox(height: 12),
          m.Expanded(
            child: m.FutureBuilder<PaperPagePlan>(
              future: _preview,
              builder: (context, result) {
                if (result.hasError) return m.Text('${result.error}');
                final plan = result.data;
                if (plan == null) {
                  return const m.Center(child: m.CircularProgressIndicator());
                }
                final prepared = plan.passages.map((p) => p.text).join('\n\n');
                final excluded = plan.blocks.where((b) => !b.included).toList();
                return m.SingleChildScrollView(
                  child: m.Column(
                    crossAxisAlignment: m.CrossAxisAlignment.start,
                    children: [
                      m.Text(
                        plan.issue ?? plan.description,
                        style: const m.TextStyle(fontWeight: m.FontWeight.bold),
                      ),
                      if (widget.savedPlanVersion != null &&
                          widget.savedPlanVersion != PaperPlanner.version)
                        const m.Text(
                          'The reading plan has changed. Check this preview before resuming.',
                        ),
                      if (widget.anchor?.contextAfter.isNotEmpty == true)
                        m.Text(
                          'Last read near: ${widget.anchor!.contextAfter}…',
                        ),
                      if (widget.anchor != null &&
                          _page == widget.anchor!.page &&
                          widget.anchor!.textHash != plan.page.textHash)
                        const m.Text(
                          'The saved text has changed. Start again from this page.',
                        ),
                      const m.SizedBox(height: 8),
                      m.SelectableText(
                        String.fromCharCodes(prepared.runes.take(16000)),
                      ),
                      if (prepared.runes.length > 16000)
                        const m.Text(
                          'Showing the first 16,000 characters of this page.',
                        ),
                      if (excluded.isNotEmpty)
                        m.ExpansionTile(
                          title: m.Text(
                            '${excluded.length} excluded text blocks',
                          ),
                          children: [
                            for (final block in excluded.take(20))
                              m.ListTile(
                                dense: true,
                                title: m.Text(block.text),
                                subtitle: m.Text(switch (block.kind) {
                                  PaperBlockKind.runningMatter =>
                                    'Header or footer',
                                  PaperBlockKind.caption =>
                                    'Figure or table caption',
                                  PaperBlockKind.references => 'References',
                                  PaperBlockKind.heading => 'Heading',
                                  PaperBlockKind.paragraph => 'Paragraph',
                                }),
                              ),
                          ],
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
    actions: [
      m.TextButton(
        onPressed: () => m.Navigator.pop(context),
        child: const m.Text('Cancel'),
      ),
      m.FutureBuilder<PaperPagePlan>(
        future: _preview,
        builder: (context, result) {
          final plan = result.data;
          final ready =
              result.connectionState == m.ConnectionState.done &&
              plan != null &&
              plan.issue == null &&
              plan.passages.isNotEmpty;
          final anchor = widget.anchor;
          final resume =
              ready &&
              anchor != null &&
              anchor.page == _page &&
              anchor.textHash == plan.page.textHash;
          return m.FilledButton(
            onPressed: ready
                ? () => m.Navigator.pop(
                    context,
                    PaperReadingChoice(_page, _options, resume ? anchor : null),
                  )
                : null,
            child: m.Text(
              resume ? 'Read from saved position' : 'Read from this page',
            ),
          );
        },
      ),
    ],
  );
}
