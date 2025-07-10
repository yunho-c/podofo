import 'package:shadcn_flutter/shadcn_flutter.dart';

class ThumbnailCard extends StatefulWidget {
  final Widget thumbnail;
  final String label;
  final VoidCallback onPressed;

  const ThumbnailCard({
    super.key,
    required this.thumbnail,
    required this.label,
    required this.onPressed,
  });

  @override
  State<ThumbnailCard> createState() => _ThumbnailCardState();
}

class _ThumbnailCardState extends State<ThumbnailCard> {
  final FocusNode _focusNode = FocusNode();
  bool _isFocused = false;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_handleFocusChange);
  }

  @override
  void dispose() {
    _focusNode.removeListener(_handleFocusChange);
    _focusNode.dispose();
    super.dispose();
  }

  void _handleFocusChange() {
    if (_focusNode.hasFocus != _isFocused) {
      setState(() {
        _isFocused = _focusNode.hasFocus;
      });
      if (_focusNode.hasFocus) {
        widget.onPressed();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Button(
      focusNode: _focusNode,
      style: ButtonVariance.menu,
      alignment: AlignmentDirectional.centerStart,
      child: Row(children: [Expanded(child: widget.thumbnail)]),
      onPressed: () {
        if (_focusNode.hasFocus) {
          widget.onPressed();
        } else {
          _focusNode.requestFocus();
        }
      },
    );
  }
}
