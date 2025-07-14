import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'package:podofo_one/src/data/document_data.dart';
import 'package:podofo_one/src/utils/responsive_icon.dart';
import 'package:podofo_one/src/utils/text_utils.dart';

final double tabWidth = 300;

class TabWidget extends StatefulWidget {
  const TabWidget({
    super.key,
    required this.document,
    required this.isSelected,
    required this.onTap,
    required this.onClose,
  });

  final Document document;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  State<TabWidget> createState() => _TabWidgetState();
}

class _TabWidgetState extends State<TabWidget> {
  bool _isHovering = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Button(
      onPressed: widget.onTap,
      onHover: (hovering) {
        setState(() {
          _isHovering = hovering;
        });
      },
      // style: ButtonStyle.ghost(),
      style: ButtonStyle.ghost().copyWith(
        padding: (context, states, resolved) =>
            const EdgeInsets.symmetric(horizontal: 12),
        decoration: (context, states, decoration) {
          return BoxDecoration(
            color: widget.isSelected ? colorScheme.muted : Colors.transparent,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(8),
              topRight: Radius.circular(8),
            ),
          );
        },
        textStyle: (context, states, resolved) => widget.isSelected
            ? TextStyle(
                fontWeight: FontWeight.w600,
                color: colorScheme.foreground,
              )
            : TextStyle(
                fontWeight: FontWeight.w500,
                color: colorScheme.mutedForeground,
              ),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: tabWidth),
        child: Row(
          // spacing: 1.0,
          children: [
            Expanded(
              child: Text(
                removePdfExtension(widget.document.title),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (_isHovering)
              IconButton(
                icon: const ResponsiveIcon(
                  lightThemeIcon: Icon(Icons.close, size: 16),
                  darkThemeIcon: Icon(
                    Icons.close,
                    size: 16,
                    color: Colors.white,
                  ),
                ),
                onPressed: widget.onClose,
                variance: ButtonStyle.ghostIcon(),
              ),
          ],
        ),
      ),
    );
  }
}
