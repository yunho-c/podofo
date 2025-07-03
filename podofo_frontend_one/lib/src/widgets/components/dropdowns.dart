import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'package:podofo_one/src/widgets/components/hotkey_editor.dart';

DropdownMenu moreOptionsDropdown = DropdownMenu(
  children: [
    // MenuDivider(),
    MenuButton(
      child: const Text('Utilities'),
      trailing: const Text('⌘⌥U').xSmall.muted,
      subMenu: [
        MenuButton(child: Text('Smart Rename')),
        MenuButton(child: Text('Optimize File Size')),
        MenuButton(child: Text('Re-Draw Text Boundaries')),
        MenuButton(
          enabled: false,
          child: const Text('Translate').xSmall.medium.muted,
        ),
        MenuButton(
          child: Text('Dynamic'),
          trailing: Switch(value: false, onChanged: (value) {}),
        ),
        MenuButton(
          child: Text('Static'),
          trailing: Switch(value: false, onChanged: (value) {}),
        ),
      ],
    ),
    MenuButton(child: Text('Extensions'), trailing: Text('⌘⌥E').xSmall.muted),
    MenuButton(child: Text('Settings'), trailing: Text('⌘⌥S').xSmall.muted),
    MenuButton(
      child: Text('Hotkeys'),
      trailing: Text('⌘⌥H').xSmall.muted,
      onPressed: (context) => {HotkeyEditor.show(context)},
    ),
    MenuDivider(),
    // MenuButton(
    //   subMenu: [
    MenuButton(enabled: false, child: Text('Community').xSmall.medium.muted),
    MenuButton(child: Text('Bug Tracker')),
    MenuButton(child: Text('Discord')),
    //   ],
    //   child: Text('Community'),
    // ),
    MenuButton(child: Text('GitHub')),
    MenuButton(child: Text('Blog')),
    MenuDivider(),
    // MenuButton(
    //   enabled: false,
    //   child: Text(
    //     'Thank you for using PoDoFo!',
    //   ).xSmall.medium.muted,
    // ),
    MenuLabel(child: Text('PoDoFo')),
    MenuLabel(child: Text('Version X.X.X').xSmall.muted),
    MenuButton(child: Text('Donate')),
    MenuButton(child: Text('Contributors')),
    MenuButton(child: Text('Open-Source')),
  ],
);
