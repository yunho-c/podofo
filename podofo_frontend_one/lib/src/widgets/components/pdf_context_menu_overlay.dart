import 'package:flutter/widgets.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' show kDefaultDuration;

/// Paints the menu outside the PDF's image filter while keeping its theme,
/// position within the viewer, and the standard dropdown's fade/scale transition.
/// Keep this widget mounted with a null child to animate dismissal.
class PdfContextMenuOverlay extends StatefulWidget {
  const PdfContextMenuOverlay({
    super.key,
    required this.anchor,
    required this.child,
    this.deferEntrance = false,
  });

  final Offset? anchor;
  final Widget? child;

  /// Wait for [markContentReady] when the menu first needs asynchronous data.
  final bool deferEntrance;

  static void markContentReady(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_MenuPresentation>()
      ?.state
      ._contentReady();

  static bool isInteractive(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_MenuPresentation>()
          ?.interactive ??
      true;

  @override
  State<PdfContextMenuOverlay> createState() => _PdfContextMenuOverlayState();
}

class _PdfContextMenuOverlayState extends State<PdfContextMenuOverlay>
    with SingleTickerProviderStateMixin {
  final _controller = OverlayPortalController()..show();
  late final AnimationController _animation;
  late final Animation<double> _scale;
  Widget? _child;
  Key _menuKey = UniqueKey();
  Offset _anchor = Offset.zero;
  bool _awaitingContent = false;
  bool _readyScheduled = false;
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    _animation = AnimationController(vsync: this)
      ..addStatusListener((status) {
        if (status == AnimationStatus.dismissed && widget.child == null) {
          setState(() => _child = null);
        }
      });
    _scale = Tween<double>(begin: 0.9, end: 1).animate(_animation);
    _updateMenu();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (_reduceMotion) {
      _animation.value = widget.child == null || _awaitingContent ? 0 : 1;
    }
  }

  @override
  void didUpdateWidget(covariant PdfContextMenuOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.child != null) {
      if (oldWidget.child == null) {
        _updateMenu();
      } else {
        _child = widget.child;
        _anchor = widget.anchor ?? _anchor;
      }
    } else if (oldWidget.child != null) {
      _awaitingContent = false;
      if (_reduceMotion || _animation.value == 0) {
        _animation.value = 0;
        _child = null;
      } else {
        // Match shadcn_flutter 0.0.54's popover: 150 ms on dismissal,
        // reaching zero at 2/3 of the duration before removing the overlay.
        _animation.animateBack(
          0,
          duration: kDefaultDuration,
          curve: const Interval(0, 2 / 3),
        );
      }
    }
  }

  void _updateMenu() {
    _menuKey = UniqueKey();
    _child = widget.child;
    _anchor = widget.anchor ?? _anchor;
    _awaitingContent = widget.child != null && widget.deferEntrance;
    _animation.stop();
    if (_awaitingContent) {
      _animation.value = 0;
    } else if (widget.child != null) {
      _show();
    }
  }

  void _show() {
    if (_reduceMotion) {
      _animation.value = 1;
    } else {
      // showDropdown currently enters linearly over 100 ms.
      _animation.animateTo(1, duration: const Duration(milliseconds: 100));
    }
  }

  void _contentReady() {
    if (!_awaitingContent || _readyScheduled || widget.child == null) return;
    _readyScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _readyScheduled = false;
      if (!mounted || !_awaitingContent || widget.child == null) return;
      _awaitingContent = false;
      _show();
    });
  }

  @override
  void dispose() {
    _animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => OverlayPortal.overlayChildLayoutBuilder(
    controller: _controller,
    overlayLocation: OverlayChildLocation.rootOverlay,
    overlayChildBuilder: (context, info) => _child == null
        ? const SizedBox.shrink()
        : Positioned.fromRect(
            rect: MatrixUtils.transformRect(
              info.childPaintTransform,
              Offset.zero & info.childSize,
            ),
            child: CustomSingleChildLayout(
              delegate: DesktopTextSelectionToolbarLayoutDelegate(
                // Scrolling may move the anchor above or left of the pane. The
                // delegate handles overflow at the other two edges.
                anchor: Offset(
                  _anchor.dx.clamp(0.0, double.infinity),
                  _anchor.dy.clamp(0.0, double.infinity),
                ),
              ),
              child: IgnorePointer(
                ignoring: widget.child == null,
                child: ExcludeFocus(
                  excluding: widget.child == null,
                  child: ExcludeSemantics(
                    excluding: widget.child == null,
                    child: FadeTransition(
                      opacity: _animation,
                      child: ScaleTransition(
                        scale: _scale,
                        alignment: Alignment.topLeft,
                        child: _MenuPresentation(
                          state: this,
                          interactive: widget.child != null,
                          child: KeyedSubtree(key: _menuKey, child: _child!),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
    child: const SizedBox.expand(),
  );
}

class _MenuPresentation extends InheritedWidget {
  const _MenuPresentation({
    required this.state,
    required this.interactive,
    required super.child,
  });

  final _PdfContextMenuOverlayState state;
  final bool interactive;

  @override
  bool updateShouldNotify(_MenuPresentation oldWidget) =>
      interactive != oldWidget.interactive;
}
