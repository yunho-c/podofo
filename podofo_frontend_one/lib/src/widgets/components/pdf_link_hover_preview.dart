import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show PointerSignalEvent;
import 'package:flutter/widgets.dart' as flutter;
import 'package:shadcn_flutter/shadcn_flutter.dart';

import '../../previews/link_target.dart';

/// Viewport-clamped content. With hover callbacks, only the card receives input;
/// without them it remains an inert tooltip.
class PdfLinkHoverPreview extends StatelessWidget {
  const PdfLinkHoverPreview({
    super.key,
    required this.anchor,
    required this.label,
    this.image,
    this.imageFilter,
    this.opacity,
    this.onPointerEnter,
    this.onPointerExit,
    this.onPointerSignal,
    this.paneBounds,
    this.imageSize,
  });
  final Offset anchor;
  final String label;
  final ui.Image? image;
  // Filter only the PDF raster; the card and label use the normal app theme.
  final ui.ImageFilter? imageFilter;
  final Animation<double>? opacity;
  final VoidCallback? onPointerEnter, onPointerExit;
  final void Function(PointerSignalEvent)? onPointerSignal;

  /// PDF-pane bounds in overlay coordinates; excludes surrounding sidebars.
  final Rect? paneBounds;

  /// Desired logical size of a resolved raster, independent of display density.
  final Size? imageSize;

  static final _disabledFilter = ui.ImageFilter.blur(sigmaX: 0, sigmaY: 0);

  static Size cardSize(Size pane) => Size(
    math.max(
      0,
      math.min(
        zoomPreviewMaxSize.width,
        math.min(pane.width * .6, pane.width - 16),
      ),
    ),
    math.max(
      0,
      math.min(
        zoomPreviewMaxSize.height,
        math.min(pane.height * .6, pane.height - 16),
      ),
    ),
  );

  static Size rasterSize(Size pane) => Size(
    math.max(0, cardSize(pane).width - 24),
    math.max(0, cardSize(pane).height - 56),
  );

  @override
  Widget build(BuildContext context) => flutter.Positioned.fill(
    child: CustomSingleChildLayout(
      delegate: _HoverLayout(anchor, paneBounds, imageSize != null),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 48 || constraints.maxHeight < 48) {
            return const SizedBox.shrink();
          }
          final borderWidth =
              ComponentTheme.maybeOf<CardTheme>(context)?.borderWidth ??
              ComponentTheme.maybeOf<OutlinedContainerTheme>(context)
                  ?.borderWidth ??
              Theme.of(context).scaling;
          final horizontalInsets = 24 + 2 * borderWidth;
          final natural = image == null
              ? null
              : imageSize ??
                    Size(image!.width.toDouble(), image!.height.toDouble());
          final fitted = natural == null
              ? null
              : applyBoxFit(
                  imageSize == null ? BoxFit.contain : BoxFit.scaleDown,
                  natural,
                  Size(
                    math.max(0, constraints.maxWidth - horizontalInsets),
                    math.max(0, constraints.maxHeight - 56),
                  ),
                ).destination;
          final card = SizedBox(
            key: const ValueKey('pdf-link-hover-card'),
            width: fitted == null
                ? null
                : math.max(
                    math.min(
                      imageSize == null ? 184 : 96,
                      constraints.maxWidth,
                    ),
                    fitted.width + horizontalInsets,
                  ),
            child: Card(
              borderWidth: borderWidth,
              padding: const EdgeInsets.all(12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (image == null)
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                      ).small(),
                    )
                  else
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ).small(),
                  if (image != null)
                    Flexible(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Semantics(
                          label: 'Preview of $label',
                          image: true,
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              final size = applyBoxFit(
                                BoxFit.scaleDown,
                                fitted!,
                                constraints.biggest,
                              ).destination;
                              return Align(
                                heightFactor: 1,
                                child: SizedBox(
                                  width: size.width,
                                  height: size.height,
                                  child: ImageFiltered(
                                    enabled: imageFilter != null,
                                    imageFilter: imageFilter ?? _disabledFilter,
                                    child: RawImage(
                                      key: const ValueKey(
                                        'pdf-link-preview-image',
                                      ),
                                      image: image,
                                      fit: BoxFit.contain,
                                      filterQuality: FilterQuality.medium,
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
          final content = opacity == null
              ? card
              : FadeTransition(opacity: opacity!, child: card);
          if (onPointerEnter == null) return IgnorePointer(child: content);
          return MouseRegion(
            onEnter: (_) => onPointerEnter?.call(),
            onExit: (_) => onPointerExit?.call(),
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerSignal: onPointerSignal,
              child: content,
            ),
          );
        },
      ),
    ),
  );
}

class _HoverLayout extends SingleChildLayoutDelegate {
  const _HoverLayout(this.anchor, this.paneBounds, this.followsZoom);
  final Offset anchor;
  final Rect? paneBounds;
  final bool followsZoom;

  Rect _bounds(Size size) =>
      (paneBounds ?? (Offset.zero & size)).intersect(Offset.zero & size);

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final pane = _bounds(constraints.biggest);
    final available = paneBounds == null
        ? Size(math.max(0, pane.width - 16), math.max(0, pane.height - 16))
        : PdfLinkHoverPreview.cardSize(pane.size);
    final limit = followsZoom ? zoomPreviewMaxSize : semanticPreviewMaxSize;
    return BoxConstraints(
      maxWidth: math.min(limit.width, available.width),
      maxHeight: math.min(limit.height, available.height),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final pane = _bounds(size);
    final top = anchor.dy + 15 + childSize.height <= pane.bottom - 8
        ? anchor.dy + 15
        : anchor.dy - 15 - childSize.height;
    final left = anchor.dx + 15 + childSize.width <= pane.right - 8
        ? anchor.dx + 15
        : anchor.dx - 15 - childSize.width;
    return Offset(
      left.clamp(
        pane.left + 8,
        math.max(pane.left + 8, pane.right - childSize.width - 8),
      ),
      top.clamp(
        pane.top + 8,
        math.max(pane.top + 8, pane.bottom - childSize.height - 8),
      ),
    );
  }

  @override
  bool shouldRelayout(_HoverLayout oldDelegate) =>
      anchor != oldDelegate.anchor ||
      paneBounds != oldDelegate.paneBounds ||
      followsZoom != oldDelegate.followsZoom;
}
