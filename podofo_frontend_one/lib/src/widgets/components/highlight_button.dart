import 'package:flutter/services.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'package:podofo_one/src/providers/user_state_provider.dart';

class HighlightButton extends ConsumerWidget {
  const HighlightButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final userState = ref.watch(userStateNotifierProvider);
    return GestureDetector(
      onTap: () {
        ref
            .read(userStateNotifierProvider.notifier)
            .setHighlight(!userState.highlight);
      },
      onSecondaryTapUp: (details) {
        showDropdown(
          context: context,
          position: details.globalPosition,
          builder: (context) {
            return DropdownMenu(
              children: [
                MenuButton(
                  enabled: false,
                  child: const Text('Colors').xSmall.medium.muted,
                ),
                MenuButton(
                  enabled: false,
                  child: Text(
                    'Right-click to customize',
                    style: TextStyle(fontSize: 10),
                  ).muted,
                ),
                MenuButton(
                  enabled: false,
                  child: Avatar(
                    initials: '',
                    backgroundColor: Colors.red,
                    size: 12,
                  ),
                ),
                MenuButton(
                  enabled: false,
                  child: Avatar(
                    initials: '',
                    backgroundColor: Colors.orange,
                    size: 12,
                  ),
                ),
                MenuButton(
                  enabled: false,
                  child: Avatar(
                    initials: '',
                    backgroundColor: Colors.yellow,
                    size: 12,
                  ),
                ),
                MenuButton(
                  enabled: false,
                  child: Avatar(
                    initials: '',
                    backgroundColor: Colors.green,
                    size: 12,
                  ),
                ),
                MenuButton(
                  enabled: false,
                  child: Avatar(
                    initials: '',
                    backgroundColor: Colors.cyan,
                    size: 12,
                  ),
                ),
                MenuButton(
                  enabled: false,
                  child: Avatar(
                    initials: '',
                    backgroundColor: Colors.indigo,
                    size: 12,
                  ),
                ),
                MenuDivider(),
                const MenuButton(
                  trailing: MenuShortcut(
                    activator: SingleActivator(
                      LogicalKeyboardKey.bracketLeft,
                      control: true,
                    ),
                  ),
                  child: Text('Back'),
                ),
                const MenuButton(
                  trailing: MenuShortcut(
                    activator: SingleActivator(
                      LogicalKeyboardKey.bracketRight,
                      control: true,
                    ),
                  ),
                  enabled: false,
                  child: Text('Forward'),
                ),
                const MenuButton(
                  trailing: MenuShortcut(
                    activator: SingleActivator(
                      LogicalKeyboardKey.keyR,
                      control: true,
                    ),
                  ),
                  child: Text('Reload'),
                ),
                const MenuButton(
                  subMenu: [
                    MenuButton(
                      trailing: MenuShortcut(
                        activator: SingleActivator(
                          LogicalKeyboardKey.keyS,
                          control: true,
                        ),
                      ),
                      child: Text('Save Page As...'),
                    ),
                    MenuButton(child: Text('Create Shortcut...')),
                    MenuButton(child: Text('Name Window...')),
                    MenuDivider(),
                    MenuButton(child: Text('Developer Tools')),
                  ],
                  child: Text('More Tools'),
                ),
              ],
            );
          },
        );
      },
      child: IconButton(
        icon: FaIcon(
          FontAwesomeIcons.highlighter,
          color: userState.highlight
              ? Theme.of(context).colorScheme.foreground
              : Theme.of(context).colorScheme.mutedForeground.withAlpha(200),
        ),
        onPressed: () {
          ref
              .read(userStateNotifierProvider.notifier)
              .setHighlight(!userState.highlight);
        },
        variance: ButtonStyle.ghostIcon(),
      ),
    );
  }
}

// int people = 0;
// bool showBookmarksBar = false;
// bool showFullUrls = true;
// @override
// Widget build(BuildContext context) {
//   final theme = Theme.of(context);
//   return
//     child: DashedContainer(
//       borderRadius: BorderRadius.circular(theme.radiusMd),
//       strokeWidth: 2,
//       gap: 2,
//       child: const Text('Right click here').center(),
//     ).constrained(maxWidth: 300, maxHeight: 200),
//   );
// }
