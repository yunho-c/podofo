import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import '../providers/document_provider.dart';
import 'document_actions.dart';
import 'windows_title_bar.dart';

final desktopWindowProvider = Provider<bool>((ref) => false);

Future<void> configureWindowManager() async {
  await windowManager.ensureInitialized();
  await windowManager.setPreventClose(true);
  await windowManager.setMinimumSize(const Size(760, 520));
  final options = WindowOptions(
    titleBarStyle: Platform.isWindows
        ? TitleBarStyle.normal
        : TitleBarStyle.hidden,
  );
  await windowManager.waitUntilReadyToShow(options, () async {
    final prefs = await SharedPreferences.getInstance();
    final width = prefs.getDouble('window_width') ?? 1100;
    final height = prefs.getDouble('window_height') ?? 800;
    await windowManager.setSize(
      Size(width.clamp(760, 4000), height.clamp(520, 3000)),
    );
    // Center on an available display rather than restoring an off-screen position.
    await windowManager.center();
    await WindowsTitleBar.instance.initialize();
    await windowManager.show();
    await windowManager.focus();
  });
}

class DesktopLifecycle extends ConsumerStatefulWidget {
  const DesktopLifecycle({super.key, required this.child});
  final Widget child;
  @override
  ConsumerState<DesktopLifecycle> createState() => _DesktopLifecycleState();
}

class _DesktopLifecycleState extends ConsumerState<DesktopLifecycle>
    with WindowListener {
  bool _closing = false;
  late final bool _enabled;
  @override
  void initState() {
    super.initState();
    _enabled = ref.read(desktopWindowProvider);
    if (_enabled) windowManager.addListener(this);
  }

  @override
  void dispose() {
    if (_enabled) windowManager.removeListener(this);
    super.dispose();
  }

  @override
  Future<void> onWindowClose() async {
    if (_closing) return;
    setState(() => _closing = true);
    try {
      final documents = ref.read(loadedDocumentsProvider).values.toList();
      final decisions = <bool>[];
      for (final document in documents) {
        await document.session.waitForIdle();
        if (!mounted) return;
        final discard = await DocumentActions.resolveUnsaved(
          context,
          ref,
          document,
        );
        if (discard == null) return;
        decisions.add(discard);
      }
      try {
        final prefs = await SharedPreferences.getInstance();
        final size = await windowManager.getSize();
        await prefs.setDouble('window_width', size.width);
        await prefs.setDouble('window_height', size.height);
      } catch (_) {
        /* Optional window geometry must not prevent closing. */
      }
      // Preserve session records for next launch.
      for (var i = 0; i < documents.length; i++) {
        await documents[i].session.close(discard: decisions[i]);
      }
      await windowManager.destroy();
    } catch (e) {
      if (mounted) DocumentActions.error(ref, e);
    } finally {
      if (mounted) setState(() => _closing = false);
    }
  }

  @override
  Widget build(BuildContext context) => AbsorbPointer(
    absorbing: _closing,
    child: ExcludeFocus(excluding: _closing, child: widget.child),
  );
}
