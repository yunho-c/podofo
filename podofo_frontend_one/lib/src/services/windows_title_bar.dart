import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class WindowsTitleBarMetrics {
  const WindowsTitleBarMetrics({
    this.native = false,
    this.height = 32,
    this.buttonsWidth = 138,
  });

  final bool native;
  final double height;
  final double buttonsWidth;

  factory WindowsTitleBarMetrics.fromMap(Map<Object?, Object?> map) =>
      WindowsTitleBarMetrics(
        native: true,
        height: (map['height'] as num).toDouble(),
        buttonsWidth: (map['buttonsWidth'] as num).toDouble(),
      );
}

// Native caption controls own their visuals, input, Snap Layouts, tooltips and
// accessibility. Flutter reserves the physical region reported by the runner.
class WindowsTitleBar extends ValueNotifier<WindowsTitleBarMetrics> {
  WindowsTitleBar() : super(const WindowsTitleBarMetrics());

  static final instance = WindowsTitleBar();
  static const _channel = MethodChannel('podofo/windows_title_bar');

  Future<void> initialize() async {
    if (!Platform.isWindows) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'metricsChanged') {
        value = WindowsTitleBarMetrics.fromMap(
          call.arguments as Map<Object?, Object?>,
        );
      }
    });
    final metrics = await _channel.invokeMapMethod<Object?, Object?>(
      'initialize',
    );
    value = WindowsTitleBarMetrics.fromMap(metrics!);
  }
}
