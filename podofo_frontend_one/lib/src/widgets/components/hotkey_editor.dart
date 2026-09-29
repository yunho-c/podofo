import 'package:flutter/material.dart';

class HotkeyEditor {
  static Future<void> show(BuildContext context) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Keyboard shortcuts'),
      content: const Text(
        'Use Command on macOS, Ctrl on Windows/Linux.\n\n'
        'Ctrl+O: Open PDF\nCtrl+S: Save\nCtrl+Shift+S: Save As\n'
        'Ctrl+W: Close tab\nCtrl+Shift+H: Highlight selection\n'
        'Ctrl+F: Search document\nCtrl+B: Thumbnails\nCtrl+P: Recent files\n'
        'Ctrl+Tab / Ctrl+Shift+Tab: Next / previous tab\n'
        'Ctrl+1–9: Select tab\nCtrl+0: Last tab\nCtrl+Q: Quit',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}
