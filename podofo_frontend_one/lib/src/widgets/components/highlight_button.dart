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
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8.0),
                    child: Row(
                      children: [
                        Avatar(
                          initials: '',
                          backgroundColor: Colors.red,
                          size: 12,
                        ),
                        SizedBox(width: 8),
                        Avatar(
                          initials: '',
                          backgroundColor: Colors.orange,
                          size: 12,
                        ),
                        SizedBox(width: 8),
                        Avatar(
                          initials: '',
                          backgroundColor: Colors.yellow,
                          size: 12,
                        ),
                        SizedBox(width: 8),
                        Avatar(
                          initials: '',
                          backgroundColor: Colors.green,
                          size: 12,
                        ),
                        SizedBox(width: 8),
                        Avatar(
                          initials: '',
                          backgroundColor: Colors.cyan,
                          size: 12,
                        ),
                        SizedBox(width: 8),
                        Avatar(
                          initials: '',
                          backgroundColor: Colors.indigo,
                          size: 12,
                        ),
                        SizedBox(width: 8),
                        Avatar(
                          initials: '+',
                          backgroundColor: Colors.transparent,
                          size: 12,
                        ),
                      ],
                    ),
                  ),
                ),
                MenuDivider(),
                MenuButton(
                  subMenu: [
                    MenuButton(
                      child: Text('Use H key to toggle'),
                      trailing: Switch(value: false, onChanged: (value) {}),
                    ),
                    MenuButton(
                      child: Text('Use number keys as color change shortcut'),
                      trailing: Switch(value: false, onChanged: (value) {}),
                    ),
                    MenuButton(
                      child: Text('Use number keys as highlight shortcut'),
                      trailing: Switch(value: false, onChanged: (value) {}),
                    ),
                    MenuButton(
                      child: Text('Show highlight options in context menu'),
                      trailing: Switch(value: false, onChanged: (value) {}),
                    ),
                  ],
                  child: Text('Settings'),
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
