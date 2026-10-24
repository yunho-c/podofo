import 'package:flutter/widgets.dart';

/// Paints the menu outside the PDF's image filter while keeping its theme,
/// position within the viewer, and lifetime tied to pdfrx's menu widget.
class PdfContextMenuOverlay extends StatefulWidget {
  const PdfContextMenuOverlay({
    super.key,
    required this.anchor,
    required this.child,
  });

  final Offset anchor;
  final Widget child;

  @override
  State<PdfContextMenuOverlay> createState() => _PdfContextMenuOverlayState();
}

class _PdfContextMenuOverlayState extends State<PdfContextMenuOverlay> {
  final _controller = OverlayPortalController()..show();

  @override
  Widget build(BuildContext context) => OverlayPortal.overlayChildLayoutBuilder(
    controller: _controller,
    overlayLocation: OverlayChildLocation.rootOverlay,
    overlayChildBuilder: (context, info) => Positioned.fromRect(
      rect: MatrixUtils.transformRect(
        info.childPaintTransform,
        Offset.zero & info.childSize,
      ),
      child: CustomSingleChildLayout(
        delegate: DesktopTextSelectionToolbarLayoutDelegate(
          // Scrolling may move the anchor above or left of the pane. The
          // delegate handles overflow at the other two edges.
          anchor: Offset(
            widget.anchor.dx.clamp(0.0, double.infinity),
            widget.anchor.dy.clamp(0.0, double.infinity),
          ),
        ),
        child: widget.child,
      ),
    ),
    child: const SizedBox.expand(),
  );
}
