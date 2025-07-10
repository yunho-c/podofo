import 'package:shadcn_flutter/shadcn_flutter.dart';

class ThumbnailCard extends StatelessWidget {
  final Widget thumbnail;
  final String label;
  final FocusNode focusNode;
  final void Function(bool) onFocus;
  final VoidCallback onPressed;

  const ThumbnailCard({
    super.key,
    required this.thumbnail,
    required this.label,
    required this.onPressed,
    required this.onFocus,
    required this.focusNode,
  });

  @override
  Widget build(BuildContext context) {
    return Button(
      focusNode: focusNode,
      style: ButtonVariance.menu,
      alignment: AlignmentDirectional.centerStart,
      onFocus: onFocus,
      // onFocus: (isFocused) {
      //   if (isFocused) {}
      // },
      // onFocus: (isFocused) => onPressed(),
      onPressed: onPressed,
      // onPressed: () {
      //   if (!focusNode.hasFocus) {
      //     onPressed();
      //   }
      // },
      // onPressed: () => {},
      child: Row(children: [Expanded(child: thumbnail)]),
    );
  }
}
