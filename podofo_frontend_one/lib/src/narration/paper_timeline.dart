import 'package:flutter/foundation.dart';

import 'narrator.dart';
import 'paper_index.dart';
import 'source_map.dart';

/// Timing is independent of extraction coverage and contains no text or geometry.
class PaperTimeline extends ChangeNotifier {
  PaperTimeline(this.index) {
    index.addListener(_indexChanged);
  }
  final PaperIndex index;
  final _timings = <String, NarrationTiming>{};
  final _failures = <String, String>{};
  String? _settingsKey;
  bool planning = false, _closed = false;
  NarrationTiming? timing(String id) => _timings[id];
  String? failure(String id) => _failures[id];
  int get retainedTimingCount => _timings.length;
  void _publish() {
    if (!_closed) notifyListeners();
  }

  void _indexChanged() {
    final ids = index.snapshot.passages.map((p) => p.id).toSet();
    _timings.removeWhere((id, _) => !ids.contains(id));
    _failures.removeWhere((id, _) => !ids.contains(id));
    _publish();
  }

  void configure(NarrationSettings settings) {
    if (_settingsKey == settings.key) return;
    _settingsKey = settings.key;
    _timings.clear();
    _failures.clear();
    _publish();
  }

  void setPlanning(bool value) {
    if (planning == value) return;
    planning = value;
    _publish();
  }

  void record(IndexedPaperPassage passage, NarrationTiming value) {
    if (_closed ||
        value.textHash != passage.spokenTextHash ||
        !index.snapshot.passages.any((p) => p.id == passage.id)) {
      return;
    }
    final existing = _timings[passage.id];
    // A background prediction must never replace measured playback metadata.
    if (existing != null && existing.settingsKey == value.settingsKey) {
      final actual = {
        for (final s in existing.segments) (s.start, s.end): s.actualFrames,
      };
      var start = 0;
      final segments = <NarrationTimingSegment>[];
      for (final s in value.segments) {
        final frames = s.actualFrames ?? actual[(s.start, s.end)];
        segments.add(
          NarrationTimingSegment(
            start: s.start,
            end: s.end,
            startFrame: start,
            predictedFrames: s.predictedFrames,
            actualFrames: frames,
          ),
        );
        start += frames ?? s.predictedFrames;
      }
      value = NarrationTiming(
        textHash: value.textHash,
        settingsKey: value.settingsKey,
        sampleRate: value.sampleRate,
        estimatedFrames: start,
        durationFrames: segments.every((s) => s.actualFrames != null)
            ? start
            : null,
        segments: segments,
      );
    }
    _timings[passage.id] = value;
    _failures.remove(passage.id);
    _publish();
  }

  void fail(String id, Object error) {
    if (_closed || !index.snapshot.passages.any((p) => p.id == id)) return;
    final message = error.toString();
    _failures[id] = message.length > 512 ? message.substring(0, 512) : message;
    _publish();
  }

  void retryFailures() {
    _failures.clear();
    _publish();
  }

  PaperTimelineSnapshot get snapshot {
    final coverage = index.snapshot;
    final passages = coverage.passages.toList();
    var micros = 0, count = 0;
    var measured = true;
    for (final passage in passages) {
      final t = timing(passage.id);
      if (t == null) {
        measured = false;
        continue;
      }
      micros += _micros(t.frames, t.sampleRate);
      count++;
      measured = measured && t.measured;
    }
    final complete = coverage.fullyResolved && count == passages.length;
    return PaperTimelineSnapshot(
      knownMicroseconds: micros,
      totalMicroseconds: complete ? micros : null,
      plannedPassages: count,
      passageCount: passages.length,
      failedPassages: _failures.length,
      processedPages: coverage.processedPageCount,
      pageCount: coverage.scopeEndPage,
      unresolvedPages: coverage.unresolvedPages.length,
      planning:
          planning ||
          coverage.status == PaperIndexStatus.indexing ||
          coverage.status == PaperIndexStatus.idle,
      measured: complete && measured,
    );
  }

  /// Prefix is unknown if any preceding page or included passage is unresolved.
  int? prefixMicroseconds(String id) {
    final coverage = index.snapshot;
    var nextPage = 1, sum = 0;
    for (final page in coverage.pages) {
      if (page.page != nextPage || page.unresolved) return null;
      nextPage++;
      for (final passage in page.passages) {
        if (passage.id == id) return sum;
        final t = timing(passage.id);
        if (t == null) return null;
        sum += _micros(t.frames, t.sampleRate);
      }
    }
    return null;
  }

  DocumentPosition? position(
    NarrationPassage passage,
    NarrationTiming? local,
    NarrationSnapshot? state,
  ) {
    final id = passage.indexedPassageId;
    if (id == null) return null;
    final prefix = prefixMicroseconds(id), full = timing(id);
    if (prefix == null || full == null) return null;
    var frame = full.frameAtOffset(passage.originalOffset);
    var approximate = passage.originalOffset != 0;
    if (state != null &&
        passage.originalOffset == 0 &&
        (local == null || local.textHash == full.textHash)) {
      frame = state.positionFrames * full.sampleRate / state.sampleRate;
      approximate = false;
    } else if (state != null && local != null) {
      // Map local segment progress onto the canonical source range. Slicing can
      // change segmentation/duration; this is deliberately approximate alignment.
      for (final s in local.segments) {
        if (state.positionFrames < s.startFrame + s.frames) {
          final a = full.frameAtOffset(passage.originalOffset + s.start);
          final b = full.frameAtOffset(passage.originalOffset + s.end);
          final fraction = ((state.positionFrames - s.startFrame) / s.frames)
              .clamp(0.0, 1.0);
          frame = a + (b - a) * fraction;
          break;
        }
        frame = full.frameAtOffset(passage.originalOffset + s.end);
      }
    }
    return DocumentPosition(
      prefix + _micros(frame.clamp(0, full.frames).round(), full.sampleRate),
      approximate ||
          !full.measured ||
          !index.snapshot.passages
              .takeWhile((p) => p.id != id)
              .every((p) => timing(p.id)?.measured == true),
    );
  }

  /// Freeze source identity and segment-relative position from a complete scale.
  /// Later duration corrections cannot silently redirect this destination.
  PaperTimelineScale? freeze() {
    final total = snapshot.totalMicroseconds;
    if (total == null || total <= 0 || _settingsKey == null) return null;
    return PaperTimelineScale._(
      total,
      _settingsKey!,
      index.snapshot.passages,
      _timings,
    );
  }

  PaperSeekTarget? targetAt(int microseconds) =>
      freeze()?.targetAt(microseconds);

  bool accepts(PaperSeekTarget target) =>
      !_closed &&
      _settingsKey == target.settingsKey &&
      index.snapshot.passages.any((p) => p.id == target.passage.id) &&
      timing(target.passage.id)?.settingsKey == target.nativeSettingsKey;

  @override
  void dispose() {
    _closed = true;
    index.removeListener(_indexChanged);
    _timings.clear();
    _failures.clear();
    super.dispose();
  }
}

int _micros(int frames, int rate) =>
    (frames * Duration.microsecondsPerSecond / rate).round();

@immutable
class DocumentPosition {
  const DocumentPosition(this.microseconds, this.approximate);
  final int microseconds;
  final bool approximate;
}

@immutable
class PaperTimelineSnapshot {
  const PaperTimelineSnapshot({
    required this.knownMicroseconds,
    required this.totalMicroseconds,
    required this.plannedPassages,
    required this.passageCount,
    required this.failedPassages,
    required this.processedPages,
    required this.pageCount,
    required this.unresolvedPages,
    required this.planning,
    required this.measured,
  });
  final int knownMicroseconds,
      plannedPassages,
      passageCount,
      failedPassages,
      processedPages,
      pageCount,
      unresolvedPages;
  final int? totalMicroseconds;
  final bool planning, measured;
}

/// A source navigation destination, independent of later prefix-time changes.
@immutable
class PaperSeekTarget {
  const PaperSeekTarget(
    this.passage,
    this.settingsKey,
    this.nativeSettingsKey,
    this.start,
    this.end,
    this.fraction,
  );
  final IndexedPaperPassage passage;
  final String settingsKey, nativeSettingsKey;
  final int start, end;
  final double fraction;
  int frameIn(NarrationTiming timing) {
    if (timing.textHash != passage.spokenTextHash ||
        timing.settingsKey != nativeSettingsKey) {
      throw StateError(
        'The passage or voice changed while seeking. Try again.',
      );
    }
    final a = timing.frameAtOffset(start), b = timing.frameAtOffset(end);
    return (a + (b - a) * fraction).floor().clamp(0, timing.frames - 1);
  }
}

/// Immutable drag scale: only compact metadata is copied, never text or audio.
class PaperTimelineScale {
  PaperTimelineScale._(
    this.totalMicroseconds,
    this.settingsKey,
    Iterable<IndexedPaperPassage> values,
    Map<String, NarrationTiming> metadata,
  ) : passages = List.unmodifiable(values),
      timings = Map.unmodifiable(metadata);
  final int totalMicroseconds;
  final String settingsKey;
  final List<IndexedPaperPassage> passages;
  final Map<String, NarrationTiming> timings;
  bool isCurrent(PaperTimeline timeline) {
    if (timeline._closed || settingsKey != timeline._settingsKey) return false;
    final current = timeline.index.snapshot.passages.toList();
    return timeline.index.snapshot.fullyResolved &&
        current.length == passages.length &&
        Iterable<int>.generate(current.length).every(
          (i) =>
              current[i].id == passages[i].id &&
              timeline.timing(current[i].id)?.settingsKey ==
                  timings[current[i].id]?.settingsKey,
        );
  }

  PaperSeekTarget? targetAt(int microseconds) {
    final total = totalMicroseconds;
    var remaining = microseconds.clamp(0, total - 1);
    for (var i = 0; i < passages.length; i++) {
      final passage = passages[i], value = timings[passages[i].id]!;
      final duration = _micros(value.frames, value.sampleRate);
      if (remaining >= duration && i < passages.length - 1) {
        remaining -= duration;
        continue;
      }
      final frame =
          (remaining * value.sampleRate / Duration.microsecondsPerSecond)
              .floor()
              .clamp(0, value.frames - 1);
      final segment = value.segments.firstWhere(
        (s) => frame < s.startFrame + s.frames,
        orElse: () => value.segments.last,
      );
      return PaperSeekTarget(
        passage,
        settingsKey,
        value.settingsKey,
        segment.start,
        segment.end,
        ((frame - segment.startFrame) / segment.frames).clamp(0.0, 1.0),
      );
    }
    return null;
  }
}
