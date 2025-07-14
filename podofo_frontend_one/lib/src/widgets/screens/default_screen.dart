import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:window_manager/window_manager.dart';

import 'package:podofo_one/src/providers/ui_provider.dart';
import 'package:podofo_one/src/widgets/components/command_palette.dart';
import 'package:podofo_one/src/widgets/areas/main_area.dart';
import 'package:podofo_one/src/widgets/areas/header.dart';
import 'package:podofo_one/src/widgets/areas/title_bar.dart';
import 'package:podofo_one/src/widgets/areas/sidebar.dart';
import 'package:podofo_one/src/widgets/panes/pane_widget.dart';
import 'package:podofo_one/src/data/pane_data.dart';

class DefaultScreen extends ConsumerWidget {
  const DefaultScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final showCommandPalette = ref.watch(commandPaletteProvider);

    return Stack(
      children: [
        TitleBar(
          child: Column(
            children: [
              Header(),
              Expanded(
                child: Row(
                  children: [
                    SideBar(
                      provider: leftPaneProvider,
                      items: leftPaneData.items,
                    ),
                    PaneWidget(provider: leftPaneProvider),
                    const Expanded(child: MainArea()),
                    PaneWidget(provider: rightPaneProvider),
                    SideBar(
                      provider: rightPaneProvider,
                      items: rightPaneData.items,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (showCommandPalette) const CommandPalette(),
      ],
    );
  }
}
