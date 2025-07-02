import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'package:podofo_one/src/data/document_data.dart';
import 'package:podofo_one/src/utils/responsive_icon.dart';

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
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovering = true),
      onExit: (_) => setState(() => _isHovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          color: widget.isSelected
              ? Theme.of(context).colorScheme.muted
              : Colors.transparent,
          child: Row(
            children: [
              Text(
                widget.document.title,
                style: widget.isSelected
                    ? TextStyle(
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.foreground,
                      )
                    : TextStyle(
                        fontWeight: FontWeight.w500,
                        color: Theme.of(context).colorScheme.mutedForeground,
                      ),
              ),
              const SizedBox(width: 8),
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
      ),
    );
  }
}
