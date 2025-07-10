import 'package:flutter/widgets.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

class ThumbnailCard extends StatelessWidget {
  final Widget thumbnail;
  final String label;
  final VoidCallback onPressed;
  final void Function(bool)? onFocusChange;
  final FocusNode focusNode;

  const ThumbnailCard({
    super.key,
    required this.thumbnail,
    required this.label,
    required this.onPressed,
    required this.focusNode,
    this.onFocusChange,
  });

  @override
  Widget build(BuildContext context) {
    return Button(
      focusNode: focusNode,
      style: ButtonVariance.menu,
      alignment: AlignmentDirectional.centerStart,
      onFocus: onFocusChange,
      onPressed: onPressed,
      child: Row(children: [Expanded(child: thumbnail)]),
    );
  }
}
