import 'dart:async';

import 'package:flutter/material.dart' as m;
import 'package:shadcn_flutter/shadcn_flutter.dart';

import '../../narration/narration_controller.dart';
import '../../narration/narrator.dart';
import '../../narration/paper_sequence.dart';
import '../../narration/paper_timeline.dart';

/// Dragging previews one frozen scale; only release submits source navigation.
class DocumentNarrationTimeline extends StatefulWidget {
  const DocumentNarrationTimeline({
    super.key,
    required this.controller,
    this.developerMode = false,
  });
  final NarrationController controller;
  final bool developerMode;
  @override
  State<DocumentNarrationTimeline> createState() =>
      _DocumentNarrationTimelineState();
}

class _DocumentNarrationTimelineState extends State<DocumentNarrationTimeline> {
  PaperTimelineScale? _drag;
  PaperSequence? _dragPaper;
  double? _preview;
  int? _unavailablePage;
  String? _unavailableId;
  PaperSequence? _unavailablePaper;
  bool _beganStopped = false, _invalidatedDrag = false;
  final _focus = FocusNode();
  PaperSequence? get _paper => switch (widget.controller.source?.sequence) {
    final PaperSequence value => value,
    _ => null,
  };
  void _clear() {
    _drag = null;
    _dragPaper = null;
    _preview = null;
  }

  @override
  void didUpdateWidget(covariant DocumentNarrationTimeline oldWidget) {
    super.didUpdateWidget(oldWidget);
    final paper = _paper;
    if (_unavailablePage != null &&
        (paper == null ||
            !identical(paper, _unavailablePaper) ||
            paper.timeline.timing(_unavailableId!) != null ||
            !paper.index.snapshot.passages.any(
              (p) => p.id == _unavailableId,
            ))) {
      _unavailablePage = null;
    }
    if (_drag != null &&
        (paper == null ||
            !identical(paper, _dragPaper) ||
            !_drag!.isCurrent(paper.timeline) ||
            (!_beganStopped &&
                widget.controller.snapshot?.phase == NarrationPhase.stopped))) {
      _clear();
      _unavailablePage = null;
      _invalidatedDrag = true;
    }
  }

  void _begin(double value) {
    final paper = _paper;
    final scale = paper?.timeline.freeze();
    if (scale == null) return;
    setState(() {
      _invalidatedDrag = false;
      _unavailablePage = null;
      _drag = scale;
      _dragPaper = paper;
      _preview = value;
      _beganStopped =
          widget.controller.snapshot?.phase == NarrationPhase.stopped;
    });
  }

  void _change(double value) {
    if (_invalidatedDrag) return;
    if (_drag == null) _begin(value);
    if (_drag != null) setState(() => _preview = value);
  }

  void _end(double value) {
    final scale = _drag, paper = _paper;
    final valid =
        scale != null &&
        paper != null &&
        identical(paper, _dragPaper) &&
        scale.isCurrent(paper.timeline);
    final target = valid ? scale.targetAt(value.round()) : null;
    final unavailable = valid
        ? scale.unavailablePassageAt(value.round())
        : null;
    setState(() {
      _clear();
      _unavailablePage = unavailable?.page;
      _unavailableId = unavailable?.id;
      _unavailablePaper = unavailable == null ? null : paper;
      _invalidatedDrag = false;
    });
    if (target != null) unawaited(widget.controller.seekToTarget(target));
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller, paper = _paper;
    final document = controller.documentTimeline;
    if (paper == null || document == null) return const SizedBox.shrink();
    final total = _drag?.totalMicroseconds ?? document.totalMicroseconds;
    final position = controller.documentPosition;
    final value = _preview ?? position?.microseconds.toDouble() ?? 0;
    final enabled =
        total != null &&
        total > 0 &&
        (!controller.preparing || controller.seekingDocument);
    final estimated = !document.measured || position?.approximate == true;
    final unavailablePage = _preview != null
        ? _drag?.unavailablePassageAt(value.round())?.page
        : _unavailablePage;
    final label = _preview != null
        ? 'Seek to ${documentClock(value.round())}'
        : position == null
        ? '—'
        : '${position.approximate ? '~' : ''}${documentClock(position.microseconds)}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '$label / ${total == null ? "—" : "${document.measured ? "" : "~"}${documentClock(total)}"} · document',
                  key: const ValueKey('document-time-label'),
                ).small().muted(),
              ),
              if (total != null && position != null)
                Text(
                  '${estimated ? '~' : ''}${documentClock((total - value.round()).clamp(0, total))} remaining',
                ).small().muted(),
            ],
          ),
          Semantics(
            label: 'Document reading position',
            child: m.Slider(
              key: const ValueKey('document-narration-timeline'),
              focusNode: _focus,
              value: total == null || total <= 0
                  ? 0
                  : value.clamp(0, total).toDouble(),
              max: total == null || total <= 0 ? 1 : total.toDouble(),
              label: unavailablePage == null
                  ? 'Document ${documentClock(value.round())}'
                  : 'Page $unavailablePage: timing unavailable',
              semanticFormatterCallback: (value) =>
                  '${documentClock(value.round())} of ${total == null ? "unknown duration" : documentClock(total)}',
              onChangeStart: enabled ? _begin : null,
              onChanged: enabled ? _change : null,
              onChangeEnd: enabled ? _end : null,
            ),
          ),
          if (total == null)
            Text(
              '${document.planning ? "Estimating document duration…" : "Partial document duration"} '
              '${documentClock(document.knownMicroseconds)} planned · ${document.processedPages}/${document.pageCount} pages · '
              '${document.plannedPassages}/${document.passageCount} passages. '
              'Document seeking becomes available when reading order is resolved and timing estimates are ready.'
              '${document.unresolvedPages + document.failedPassages > 0 ? " ${document.unresolvedPages} unresolved ${document.unresolvedPages == 1 ? "page" : "pages"}, ${document.failedPassages} failed ${document.failedPassages == 1 ? "passage" : "passages"}." : ""}',
              key: const ValueKey('document-timeline-coverage'),
            ).small().muted(),
          if (widget.developerMode &&
              (document.fallbackPassages > 0 || document.failedPassages > 0))
            Row(
              key: const ValueKey('document-timeline-diagnostics'),
              children: [
                Expanded(
                  child: Text(
                    document.fallbackPassages > 0
                        ? '${document.fallbackPassages} ${document.fallbackPassages == 1 ? "passage uses" : "passages use"} rough timing. '
                              'You can seek within the other passages.'
                        : '${document.failedPassages} failed ${document.failedPassages == 1 ? "passage" : "passages"}.',
                    key: const ValueKey('document-timeline-fallback'),
                  ).small().muted(),
                ),
                if (document.failedPassages > 0 && !document.planning) ...[
                  const SizedBox(width: 8),
                  m.TextButton(
                    onPressed: paper.retryTiming,
                    child: const Text('Retry duration planning'),
                  ),
                ],
              ],
            ),
          if (unavailablePage != null)
            Semantics(
              liveRegion: true,
              child: Text(
                'Timing unavailable on page $unavailablePage. '
                '${widget.developerMode ? "Choose another position or retry duration planning." : "Choose another position."}',
                key: const ValueKey('document-timeline-unavailable'),
              ).small().muted(),
            ),
          if (controller.seekingDocument)
            const Text('Preparing reading position…').small().muted(),
        ],
      ),
    );
  }
}

String documentClock(int microseconds) {
  final seconds = microseconds ~/ Duration.microsecondsPerSecond;
  final minutes = seconds ~/ 60;
  final tail = (seconds % 60).toString().padLeft(2, '0');
  return minutes < 60
      ? '$minutes:$tail'
      : '${minutes ~/ 60}:${(minutes % 60).toString().padLeft(2, '0')}:$tail';
}
