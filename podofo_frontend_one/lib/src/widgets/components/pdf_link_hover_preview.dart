import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart' as flutter;
import 'package:shadcn_flutter/shadcn_flutter.dart';

import '../../workers/link_preview_worker.dart';

/// Inert, viewport-clamped content: clicks continue to reach the original link.
class PdfLinkHoverPreview extends StatelessWidget {
  const PdfLinkHoverPreview({
    super.key,
    required this.anchor,
    required this.label,
    this.image,
  });
  final Offset anchor;
  final String label;
  final ui.Image? image;

  @override
  Widget build(BuildContext context) => flutter.Positioned.fill(
    child: IgnorePointer(
      child: CustomSingleChildLayout(
        delegate: _HoverLayout(anchor),
        child: Card(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, maxLines: 4, overflow: TextOverflow.ellipsis).small(),
              if (image != null)
                Flexible(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Semantics(
                      label: 'Preview of $label',
                      image: true,
                      child: SizedBox(
                        width: LinkPreviewRegion.maxWidth,
                        height: LinkPreviewRegion.maxHeight,
                        child: RawImage(
                          key: const ValueKey('pdf-link-preview-image'),
                          image: image,
                          fit: BoxFit.contain,
                          filterQuality: FilterQuality.medium,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _HoverLayout extends SingleChildLayoutDelegate {
  const _HoverLayout(this.anchor);
  final Offset anchor;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints(
        maxWidth: math.min(384, math.max(0, constraints.maxWidth - 16)),
        maxHeight: math.max(0, constraints.maxHeight - 16),
      );

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final top = anchor.dy + 15 + childSize.height <= size.height - 8
        ? anchor.dy + 15
        : anchor.dy - 15 - childSize.height;
    return Offset(
      (anchor.dx + 15).clamp(
        8.0,
        math.max(8, size.width - childSize.width - 8),
      ),
      top.clamp(8.0, math.max(8, size.height - childSize.height - 8)),
    );
  }

  @override
  bool shouldRelayout(_HoverLayout oldDelegate) => anchor != oldDelegate.anchor;
}
