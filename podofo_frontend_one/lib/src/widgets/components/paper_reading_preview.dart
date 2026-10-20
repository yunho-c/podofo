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
  });
  final PaperSequence sequence;
  final int page;
  final SourceAnchor? anchor;
  @override
  m.State<PaperReadingPreview> createState() => _PaperReadingPreviewState();
}

class _PaperReadingPreviewState extends m.State<PaperReadingPreview> {
  late int _page = widget.page;
  late PaperReadOptions _options = widget.sequence.options;
  late Future<PaperPagePlan> _preview = widget.sequence.preview(_page);
  void _refresh({
    int? page,
    PaperOrder? order,
    bool? references,
    bool? captions,
  }) {
    setState(() {
      _page = page ?? _page;
      _options = PaperReadOptions(
        order: order ?? _options.order,
        stopAtReferences: references ?? _options.stopAtReferences,
        skipCaptions: captions ?? _options.skipCaptions,
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
              const m.Spacer(),
              m.DropdownButton<PaperOrder>(
                value: _options.order,
                onChanged: (value) => _refresh(order: value),
                items: [
                  for (final order in PaperOrder.values)
                    m.DropdownMenuItem(
                      value: order,
                      child: m.Text(switch (order) {
                        PaperOrder.automatic => 'Detect layout',
                        PaperOrder.singleColumn => 'One column',
                        PaperOrder.twoColumns => 'Two columns',
                        PaperOrder.pdfOrder => 'PDF text order',
                      }),
                    ),
                ],
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
            title: const m.Text('Skip figure and table captions'),
            value: _options.skipCaptions,
            onChanged: (value) => _refresh(captions: value),
          ),
          const m.Text(
            'Check that the text below follows the paper. Equations and tables may need a selected passage.',
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
                return m.SingleChildScrollView(
                  child: m.Column(
                    crossAxisAlignment: m.CrossAxisAlignment.start,
                    children: [
                      m.Text(
                        plan.issue ?? plan.description,
                        style: const m.TextStyle(fontWeight: m.FontWeight.bold),
                      ),
                      if (widget.anchor != null &&
                          _page == widget.anchor!.page &&
                          widget.anchor!.textHash != plan.page.textHash)
                        const m.Text(
                          'The saved text has changed. Start again from this page.',
                        ),
                      const m.SizedBox(height: 8),
                      m.SelectableText(
                        plan.passages.take(3).map((p) => p.text).join('\n\n'),
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
