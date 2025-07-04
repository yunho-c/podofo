import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'package:podofo_one/src/data/document_data.dart';
import 'package:podofo_one/src/utils/responsive_icon.dart';
import 'package:podofo_one/src/utils/text_utils.dart';

final double TAB_WIDTH = 300;

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
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(5),
              topRight: Radius.circular(5),
            ),
            color: widget.isSelected
                ? Theme.of(context).colorScheme.muted
                : Colors.transparent,
          ),
          child: SizedBox(
            width: TAB_WIDTH,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    removePdfExtension(widget.document.title),
                    overflow: TextOverflow.ellipsis,
                    style: widget.isSelected
                        ? TextStyle(
                            fontWeight: FontWeight.w600,
                            color: Theme.of(context).colorScheme.foreground,
                          )
                        : TextStyle(
                            fontWeight: FontWeight.w500,
                            color: Theme.of(
                              context,
                            ).colorScheme.mutedForeground,
                          ),
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
        ),
      ),
    );
  }
}
