import 'package:flutter/material.dart';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

Future<void> configureWindowManager() async {
  await windowManager.ensureInitialized();

  const windowOptions = WindowOptions(titleBarStyle: TitleBarStyle.hidden);

  windowManager.waitUntilReadyToShow(windowOptions, () async {
    final prefs = await SharedPreferences.getInstance();
    final width = prefs.getDouble('window_width');
    final height = prefs.getDouble('window_height');
    final offsetX = prefs.getDouble('window_offset_x');
    final offsetY = prefs.getDouble('window_offset_y');

    if (width != null && height != null) {
      await windowManager.setSize(Size(width, height));
    }
    if (offsetX != null && offsetY != null) {
      await windowManager.setPosition(Offset(offsetX, offsetY));
    }

    await windowManager.show();
    await windowManager.focus();
  });
}

class PodofoWindowListener extends WindowListener {
  @override
  Future<void> onWindowClose() async {
    // Save window size and position before closing
    final prefs = await SharedPreferences.getInstance();
    final size = await windowManager.getSize();
    final position = await windowManager.getPosition();
    await prefs.setDouble('window_width', size.width);
    await prefs.setDouble('window_height', size.height);
    await prefs.setDouble('window_offset_x', position.dx);
    await prefs.setDouble('window_offset_y', position.dy);
    super.onWindowClose();
  }
}
