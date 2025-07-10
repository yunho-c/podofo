import 'package:shadcn_flutter/shadcn_flutter.dart';

class ThumbnailCard extends StatelessWidget {
  final Widget thumbnail;
  final String label;
  final VoidCallback onPressed;
  final FocusNode focusNode;

  const ThumbnailCard({
    super.key,
    required this.thumbnail,
    required this.label,
    required this.focusNode,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Button(
      focusNode: focusNode,
      style: ButtonVariance.menu,
      alignment: AlignmentDirectional.centerStart,
      child: Row(children: [Expanded(child: thumbnail)]),
      onPressed: onPressed,
      onFocus: (isFocused) {
        if (isFocused) {
          onPressed();
        }
      },
    );
  }
}
