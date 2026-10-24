import 'package:flutter/material.dart' as material show Icons, Tooltip;
import 'package:shadcn_flutter/shadcn_flutter.dart';

/// The original reader's 60px hover target, 10px inset and outlined arrow.
/// Hover/focus animation is local so it never rebuilds the PDF viewer.
class PdfBackButton extends StatefulWidget {
  const PdfBackButton({super.key, required this.onPressed});

  final VoidCallback? onPressed;

  @override
  State<PdfBackButton> createState() => _PdfBackButtonState();
}

class _PdfBackButtonState extends State<PdfBackButton> {
  bool _hovering = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final touch = switch (Theme.of(context).platform) {
      TargetPlatform.android || TargetPlatform.iOS => true,
      _ => false,
    };
    final visible = _hovering || _focused || touch;
    return MouseRegion(
      hitTestBehavior: HitTestBehavior.translucent,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: SizedBox(
        width: 60,
        height: 60,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          alwaysIncludeSemantics: true,
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 100),
          child: Stack(
            children: [
              Positioned(
                top: 10,
                left: 10,
                child: IgnorePointer(
                  ignoring: !visible,
                  child: material.Tooltip(
                    message: 'Back',
                    child: IconButton(
                      key: const ValueKey('pdf-link-back'),
                      icon: const Icon(material.Icons.arrow_back_outlined),
                      variance: ButtonStyle.outlineIcon(),
                      onFocus: (focused) => setState(() => _focused = focused),
                      onPressed: widget.onPressed,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
