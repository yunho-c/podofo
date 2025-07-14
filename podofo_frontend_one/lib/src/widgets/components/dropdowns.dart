import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'package:podofo_one/src/providers/user_state_provider.dart';
import 'package:podofo_one/src/widgets/components/hotkey_editor.dart';

class MoreOptionsDropdown extends ConsumerWidget {
  const MoreOptionsDropdown({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final userState = ref.watch(userStateNotifierProvider);
    final userStateNotifier = ref.read(userStateNotifierProvider.notifier);
    return DropdownMenu(
      children: [
        MenuButton(
          child: const Text('Auto-Save'),
          trailing: Switch(
            value: userState.autoSaveEnabled,
            onChanged: (value) {
              userStateNotifier.setAutoSaveEnabled(value);
            },
          ),
        ),
        const MenuDivider(),
        MenuButton(
          child: const Text('Utilities'),
          // trailing: const Text('⌘⌥U').xSmall.muted,
          trailing: const MenuShortcut(
            activator: SingleActivator(
              LogicalKeyboardKey.keyU,
              meta: true,
              alt: true,
            ),
          ),
          subMenu: [
            const MenuButton(child: Text('Smart Rename')),
            const MenuButton(child: Text('Optimize File Size')),
            const MenuButton(child: Text('Re-Draw Text Boundaries')),
            const MenuButton(child: Text('Generate outlines')),
            MenuButton(
              enabled: false,
              child: const Text('Translate').xSmall.medium.muted,
            ),
            MenuButton(
              child: const Text('Static'),
              trailing: Switch(value: false, onChanged: (value) {}),
            ),
            MenuButton(
              child: const Text('Dynamic'),
              trailing: Switch(value: false, onChanged: (value) {}),
            ),
          ],
        ),
        MenuButton(
          child: Text('Extensions'),
          trailing: Text('⌘⌥E').xSmall.muted,
        ),
        MenuButton(
          child: const Text('Hotkeys'),
          trailing: const Text('⌘⌥H').xSmall.muted,
          onPressed: (context) => {HotkeyEditor.show(context)},
        ),
        MenuButton(child: Text('Settings'), trailing: Text('⌘⌥S').xSmall.muted),
        const MenuDivider(),
        // MenuButton(
        //   subMenu: [
        MenuButton(
          enabled: false,
          child: const Text('Community').xSmall.medium.muted,
        ),
        const MenuButton(child: Text('Bug Tracker')),
        const MenuButton(child: Text('Discord')),
        //   ],
        //   child: Text('Community'),
        // ),
        const MenuButton(child: Text('GitHub')),
        const MenuButton(child: Text('Blog')),
        const MenuDivider(),
        // MenuButton(
        //   enabled: false,
        //   child: Text(
        //     'Thank you for using PoDoFo!',
        //   ).xSmall.medium.muted,
        // ),
        const MenuLabel(child: Text('PoDoFo')),
        MenuLabel(child: Text('Version X.X.X').xSmall.muted),
        const MenuButton(child: Text('Donate')),
        const MenuButton(child: Text('Contributors')),
        const MenuButton(child: Text('Open-Source')),
      ],
    );
  }
}

const moreOptionsDropdown = MoreOptionsDropdown();
