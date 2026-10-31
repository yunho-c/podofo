import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart' as flutter;
import 'package:shadcn_flutter/shadcn_flutter.dart';

import '../../previews/link_target.dart';

/// Inert, viewport-clamped content: clicks continue to reach the original link.
class PdfLinkHoverPreview extends StatelessWidget {
  const PdfLinkHoverPreview({
    super.key,
    required this.anchor,
    required this.label,
    this.image,
    this.imageFilter,
  });
  final Offset anchor;
  final String label;
  final ui.Image? image;
  // Filter only the PDF raster; the card and label use the normal app theme.
  final ui.ImageFilter? imageFilter;

  static final _disabledFilter = ui.ImageFilter.blur(sigmaX: 0, sigmaY: 0);

  static Size rasterSize(Size viewport) => Size(
    math.max(
      0,
      math.min(semanticPreviewMaxSize.width, viewport.width - 16) - 24,
    ),
    math.max(
      0,
      math.min(semanticPreviewMaxSize.height, viewport.height - 16) - 56,
    ),
  );

  @override
  Widget build(BuildContext context) => flutter.Positioned.fill(
    child: IgnorePointer(
      child: CustomSingleChildLayout(
        delegate: _HoverLayout(anchor),
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth < 48 || constraints.maxHeight < 48) {
              return const SizedBox.shrink();
            }
            final natural = image == null
                ? null
                : Size(image!.width.toDouble(), image!.height.toDouble());
            final fitted = natural == null
                ? null
                : applyBoxFit(
                    BoxFit.contain,
                    natural,
                    Size(
                      math.max(0, constraints.maxWidth - 24),
                      math.max(0, constraints.maxHeight - 56),
                    ),
                  ).destination;
            return SizedBox(
              width: fitted == null
                  ? null
                  : math.max(
                      math.min(184, constraints.maxWidth),
                      fitted.width + 24,
                    ),
              child: Card(
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
                                  BoxFit.contain,
                                  Size(
                                    image!.width.toDouble(),
                                    image!.height.toDouble(),
                                  ),
                                  constraints.biggest,
                                ).destination;
                                return Align(
                                  heightFactor: 1,
                                  child: SizedBox(
                                    width: size.width,
                                    height: size.height,
                                    child: ImageFiltered(
                                      enabled: imageFilter != null,
                                      imageFilter:
                                          imageFilter ?? _disabledFilter,
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
          },
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
        maxWidth: math.min(
          semanticPreviewMaxSize.width,
          math.max(0, constraints.maxWidth - 16),
        ),
        maxHeight: math.min(
          semanticPreviewMaxSize.height,
          math.max(0, constraints.maxHeight - 16),
        ),
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
