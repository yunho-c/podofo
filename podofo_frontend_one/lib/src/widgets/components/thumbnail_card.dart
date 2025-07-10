import 'package:shadcn_flutter/shadcn_flutter.dart';

class ThumbnailCard extends StatelessWidget {
  final Widget thumbnail;
  final String label;
  final FocusNode focusNode;
  final ValueChanged<bool> onFocus;
  final VoidCallback onPressed;

  const ThumbnailCard({
    super.key,
    required this.thumbnail,
    required this.label,
    required this.focusNode,
    required this.onFocus,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    // final theme = Theme.of(context);
    return Button(
      focusNode: focusNode,
      onFocus: onFocus,
      style: ButtonVariance.menu,
      alignment: AlignmentDirectional.centerStart,
      child: Row(children: [Expanded(child: thumbnail)]),
      onPressed: () {
        if (!focusNode.hasFocus) {
          focusNode.requestFocus();
        }
        onPressed();
      },
    );
  }
}
