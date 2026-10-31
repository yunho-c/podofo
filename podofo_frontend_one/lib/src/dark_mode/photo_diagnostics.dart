import 'package:flutter/widgets.dart';

import 'photo_analysis.dart';

enum PhotoDiagnosticStatus { preserved, rejected, skipped }

class PhotoDiagnosticEntry {
  PhotoDiagnosticEntry({
    required this.pageNumber,
    required this.candidate,
    required this.rect,
    required bool preserved,
    required String inactiveReason,
    this.override,
    this.includeTranslucent = false,
  }) : reason = override == false
           ? switch (inactiveReason) {
               'inversion-off' ||
               'preservation-off' ||
               'selective-shader-unavailable' => inactiveReason,
               _ => rect.isEmpty ? 'outside-viewport' : 'user-inverted',
             }
           : candidate.reason == 'likely-photo' || override == true
           ? preserved
                 ? override == true
                       ? 'user-preserved'
                       : 'preserved'
                 : rect.isEmpty
                 ? 'outside-viewport'
                 : inactiveReason
           : candidate.reason;

  final int pageNumber;
  final PhotoCandidate candidate;
  final bool? override;
  final bool includeTranslucent;

  /// Normalized to the viewer viewport, after page rotation and cropping.
  final Rect rect;
  final String reason;
  String get label => 'P$pageNumber image #${candidate.objectId}';
  PhotoDiagnosticStatus get status {
    if (reason == 'preserved' || reason == 'user-preserved') {
      return PhotoDiagnosticStatus.preserved;
    }
    if (override != null ||
        candidate.reason == 'likely-photo' ||
        const {
          'pending',
          'analysis-stalled',
          'analysis-unavailable',
          'image-unavailable',
          'time-budget',
          'image-budget',
          'image-pixel-budget',
          'page-pixel-budget',
          'image-size-unavailable',
          'decode-failed',
          'unsupported-bitmap',
          'opacity-unavailable',
          'rendered-image-budget',
          'form-depth-budget',
          'object-budget',
        }.contains(reason)) {
      return PhotoDiagnosticStatus.skipped;
    }
    return PhotoDiagnosticStatus.rejected;
  }

  Color get color => switch (status) {
    PhotoDiagnosticStatus.preserved => const Color(0xff36d987),
    PhotoDiagnosticStatus.rejected => const Color(0xffffb347),
    PhotoDiagnosticStatus.skipped => const Color(0xffc5cbd3),
  };
}

class PhotoDiagnosticPage {
  const PhotoDiagnosticPage(this.pageNumber, this.analysis, this.entries);
  final int pageNumber;

  /// Null means queued or still being inspected, not an empty page.
  final PhotoPageAnalysis? analysis;
  final List<PhotoDiagnosticEntry> entries;
}

class PhotoDiagnosticsSnapshot {
  const PhotoDiagnosticsSnapshot({
    required this.revision,
    required this.pages,
    this.omittedPages = 0,
    this.pageCapacity = 64,
    this.textureWidth,
    this.textureHeight,
  });
  final int revision;
  final List<PhotoDiagnosticPage> pages;
  final int omittedPages, pageCapacity;
  final int? textureWidth, textureHeight;
  Iterable<PhotoDiagnosticEntry> get entries => pages.expand((p) => p.entries);
}

/// Shared only by one session's viewer and developer pane. Publish after paint
/// so viewer/controller notifications never rebuild the sidebar during build.
class PhotoDiagnosticsController
    extends ValueNotifier<PhotoDiagnosticsSnapshot?> {
  PhotoDiagnosticsController() : super(null);
  PhotoDiagnosticsSnapshot? _pending;
  bool _scheduled = false;
  bool _disposed = false;

  void publish(PhotoDiagnosticsSnapshot? snapshot) {
    if (_disposed) return;
    _pending = snapshot;
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!_disposed) value = _pending;
    });
    // Also deliver updates requested while idle (for example, clearing a tab).
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    _disposed = true;
    _pending = null;
    super.dispose();
  }
}

/// Painted outside ImageFiltered. Neither outlines nor labels intercept input.
class PhotoDiagnosticsOverlay extends StatelessWidget {
  const PhotoDiagnosticsOverlay({super.key, required this.snapshot});
  final PhotoDiagnosticsSnapshot snapshot;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: ExcludeSemantics(
      // Accessible details are available in the developer sidebar instead.
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _PhotoDiagnosticsPainter(
            snapshot,
            DefaultTextStyle.of(context).style,
          ),
        ),
      ),
    ),
  );
}

class _PhotoDiagnosticsPainter extends CustomPainter {
  _PhotoDiagnosticsPainter(this.snapshot, this.textStyle);
  final PhotoDiagnosticsSnapshot snapshot;
  final TextStyle textStyle;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    for (final entry in snapshot.entries) {
      if (entry.rect.isEmpty) continue;
      final rect = Rect.fromLTRB(
        entry.rect.left * size.width,
        entry.rect.top * size.height,
        entry.rect.right * size.width,
        entry.rect.bottom * size.height,
      );
      // A dark keyline keeps outlines readable over white and textured photos.
      canvas.drawRect(
        rect.deflate(1),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4
          ..color = const Color(0xff15191f),
      );
      canvas.drawRect(
        rect.deflate(1),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = entry.color,
      );
      final text = TextPainter(
        text: TextSpan(
          text: '${entry.label}: ${entry.reason}',
          style: textStyle.copyWith(fontSize: 11, color: entry.color),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 2,
        ellipsis: '…',
      )..layout(maxWidth: (size.width - rect.left - 8).clamp(1, 320));
      final origin = Offset(
        rect.left + 3,
        rect.top.clamp(
          0,
          (size.height - text.height - 4).clamp(0, size.height),
        ),
      );
      canvas.drawRect(
        origin & Size(text.width + 4, text.height + 4),
        Paint()..color = const Color(0xee15191f),
      );
      text.paint(canvas, origin + const Offset(2, 2));
      text.dispose();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _PhotoDiagnosticsPainter oldDelegate) =>
      oldDelegate.snapshot != snapshot || oldDelegate.textStyle != textStyle;
}
