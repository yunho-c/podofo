import 'package:shadcn_flutter/shadcn_flutter.dart';

class ThumbnailCard extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // final scaling = theme.scaling;

    return Button(
      style: ButtonVariance.menu,
      disableFocusOutline: true,
      alignment: AlignmentDirectional.centerStart,
      child: Row(
        children: [
          Expanded(child: thumbnail),
        ],
      ),
      onPressed: () => onPressed(),
    );
  }
}
