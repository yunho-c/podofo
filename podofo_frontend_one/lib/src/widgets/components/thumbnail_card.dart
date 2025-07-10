import 'package:shadcn_flutter/shadcn_flutter.dart';

class ThumbnailCard extends StatelessWidget {
  final Widget thumbnail;
  final String label;
  final VoidCallback onPressed;
  final bool active;

  const ThumbnailCard({
    super.key,
    required this.thumbnail,
    required this.label,
    required this.onPressed,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // final scaling = theme.scaling;
    final activeButtonVariance = ButtonVariance.menu.withBackgroundColor(
      color: theme.colorScheme.primary.withAlpha(50),
    );

    return Button(
      style: active ? activeButtonVariance : ButtonVariance.menu,
      disableFocusOutline: true,
      alignment: AlignmentDirectional.centerStart,
      child: Row(children: [Expanded(child: thumbnail)]),
      onPressed: () => onPressed(),
    );
  }
}
