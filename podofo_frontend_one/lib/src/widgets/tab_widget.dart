import 'package:flutter/material.dart';
import 'package:flutter/material.dart' hide Tab;
import 'package:podofo_one/src/tabs.dart' as custom_tabs;

class TabWidget extends StatefulWidget {
  const TabWidget({
    super.key,
    required this.tab,
    required this.isSelected,
    required this.onTap,
    required this.onClose,
  });

  final custom_tabs.Tab tab;
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
          color: widget.isSelected ? Theme.of(context).colorScheme.background : Colors.transparent,
          child: Row(
            children: [
              Text(widget.tab.title),
              const SizedBox(width: 8),
              if (_isHovering)
                IconButton(
                  icon: const Icon(Icons.close, size: 16),
                  onPressed: widget.onClose,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
