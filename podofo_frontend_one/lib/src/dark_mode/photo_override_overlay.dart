import 'dart:ui' show ViewFocusEvent, ViewFocusState;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:pdfrx/pdfrx.dart';

class PhotoOverrideEntry {
  const PhotoOverrideEntry({
    required this.target,
    required this.rect,
    required this.automatic,
    required this.override,
  });
  final String target;
  final Rect rect; // Normalized viewport coordinates.
  final bool automatic;
  final bool? override;
  bool get preserve => override ?? automatic;
  String get label =>
      '${override == null ? 'Automatic' : 'Override'}: '
      '${preserve ? 'original colors' : 'dark mode'}. '
      '${override != null
          ? 'Click to return to Automatic.'
          : preserve
          ? 'Click to apply dark mode.'
          : 'Click to keep original colors.'}';
}

/// Modifier state is local: pressing Alt never remounts or rebuilds the PDF.
class PhotoOverrideOverlay extends StatefulWidget {
  const PhotoOverrideOverlay({
    super.key,
    required this.enabled,
    required this.entries,
    required this.controller,
    required this.onToggle,
    this.error,
  });
  final bool enabled;
  final List<PhotoOverrideEntry> entries;
  final PdfViewerController controller;
  final ValueChanged<PhotoOverrideEntry> onToggle;
  final String? error;

  @override
  State<PhotoOverrideOverlay> createState() => _PhotoOverrideOverlayState();
}

class _PhotoOverrideOverlayState extends State<PhotoOverrideOverlay>
    with WidgetsBindingObserver {
  bool _alt = false, _focused = true;
  String? _hover;

  @override
  void initState() {
    super.initState();
    _alt = HardwareKeyboard.instance.isAltPressed;
    HardwareKeyboard.instance.addHandler(_onKey);
    WidgetsBinding.instance.addObserver(this);
  }

  bool _onKey(KeyEvent event) {
    final alt = _focused && HardwareKeyboard.instance.isAltPressed;
    if (_alt != alt) {
      setState(() {
        _alt = alt;
        _hover = null;
      });
    }
    return false;
  }

  void _focus(bool focused) {
    if (_focused == focused) return;
    setState(() {
      _focused = focused;
      _alt = false;
      _hover = null;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _focus(state == AppLifecycleState.resumed);
  }

  @override
  void didChangeViewFocus(ViewFocusEvent event) {
    if (event.viewId == View.of(context).viewId) {
      _focus(event.state == ViewFocusState.focused);
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled || !_alt) return const SizedBox.shrink();
    // Small panels get the hit target when outlines nest or overlap.
    final entries = widget.entries.toList()
      ..sort(
        (a, b) => (b.rect.width * b.rect.height).compareTo(
          a.rect.width * a.rect.height,
        ),
      );
    final hovered = entries.where((e) => e.target == _hover).firstOrNull;
    return LayoutBuilder(
      builder: (context, constraints) {
        return Stack(
          children: [
            for (final entry in entries)
              Positioned.fromRect(
                key: ValueKey('photo-override-${entry.target}'),
                rect: Rect.fromLTRB(
                  entry.rect.left * constraints.maxWidth,
                  entry.rect.top * constraints.maxHeight,
                  entry.rect.right * constraints.maxWidth,
                  entry.rect.bottom * constraints.maxHeight,
                ),
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  onEnter: (_) => setState(() => _hover = entry.target),
                  onExit: (_) => setState(() => _hover = null),
                  child: Listener(
                    onPointerSignal: widget.controller.handlePointerSignalEvent,
                    child: Semantics(
                      button: true,
                      label: entry.label,
                      onTap: () => widget.onToggle(entry),
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        excludeFromSemantics: true,
                        onTap: () => widget.onToggle(entry),
                        child: CustomPaint(
                          painter: _Outline(
                            preserve: entry.preserve,
                            overridden: entry.override != null,
                            hovered: entry.target == _hover,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            Positioned(
              left: 12,
              right: 12,
              bottom: 12,
              child: IgnorePointer(
                child: Center(
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 460),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xf020242d),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      widget.error ??
                          hovered?.label ??
                          (entries.isEmpty
                              ? 'No adjustable images in view.'
                              : 'Click an outlined image to switch its colors. Click again for Automatic.'),
                      style: const TextStyle(
                        color: Color(0xfff5f5f5),
                        fontSize: 12,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _Outline extends CustomPainter {
  const _Outline({
    required this.preserve,
    required this.overridden,
    required this.hovered,
  });
  final bool preserve, overridden, hovered;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(2);
    final color = preserve ? const Color(0xff36d987) : const Color(0xffffb347);
    final paint = Paint()..style = PaintingStyle.stroke;
    canvas.drawRect(
      rect,
      paint
        ..color = const Color(0xff15191f)
        ..strokeWidth = 5,
    );
    canvas.drawRect(
      rect,
      paint
        ..color = color
        ..strokeWidth = hovered || overridden ? 3 : 1.5,
    );
    if (overridden) {
      canvas.drawCircle(
        rect.topLeft + const Offset(5, 5),
        3,
        Paint()..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(_Outline old) =>
      old.preserve != preserve ||
      old.overridden != overridden ||
      old.hovered != hovered;
}
