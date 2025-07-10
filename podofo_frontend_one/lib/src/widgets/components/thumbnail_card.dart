import 'package:shadcn_flutter/shadcn_flutter.dart';

class ThumbnailCard extends StatelessWidget {
  final Widget thumbnail;
  final String label;
  final FocusNode focusNode;
  final VoidCallback onPressed;

  const ThumbnailCard({
    super.key,
    required this.thumbnail,
    required this.label,
    required this.onPressed,
    required this.focusNode,
  });

  @override
  Widget build(BuildContext context) {
    return Button(
      focusNode: focusNode,
      style: ButtonVariance.menu,
      alignment: AlignmentDirectional.centerStart,
      // onFocus: (isFocused) {
      //   if (isFocused) {}
      // },
      // onFocus: (isFocused) => onPressed(),
      // onPressed: onPressed,
      onPressed: () {
        if (!focusNode.hasFocus) {
          onPressed();
        }
      },
      // onPressed: () => {},
      child: Row(children: [Expanded(child: thumbnail)]),
    );
  }
}
