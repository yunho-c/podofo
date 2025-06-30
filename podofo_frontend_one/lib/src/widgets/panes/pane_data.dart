import 'package:flutter/material.dart';
import 'package:podofo_one/src/utils/responsive_icon.dart';

import 'package:podofo_one/src/widgets/areas/sidebar.dart';

import 'package:podofo_one/src/widgets/panes/debug_pane.dart';
import 'package:podofo_one/src/widgets/panes/explorer_pane.dart';
import 'package:podofo_one/src/widgets/panes/extensions_pane.dart';
import 'package:podofo_one/src/widgets/panes/outline_pane.dart';
import 'package:podofo_one/src/widgets/panes/search_pane.dart';
import 'package:podofo_one/src/widgets/panes/thumbnail_pane.dart';
import 'package:podofo_one/src/widgets/panes/timeline_pane.dart';

class PaneData {
  final List<SideBarItem> items;

  PaneData({required this.items});
}

final leftPaneData = () {
  return PaneData(
    items: [
      SideBarItem(
          icon: const ResponsiveIcon(
            lightThemeIcon: Icon(Icons.grid_view),
            darkThemeIcon: Icon(Icons.grid_view, color: Colors.white),
          ),
          pane: ThumbnailPane()),
      SideBarItem(
          icon: const ResponsiveIcon(
            lightThemeIcon: Icon(Icons.description),
            darkThemeIcon: Icon(Icons.description, color: Colors.white),
          ),
          pane: ExplorerPane()),
      SideBarItem(
          icon: const ResponsiveIcon(
            lightThemeIcon: Icon(Icons.search),
            darkThemeIcon: Icon(Icons.search, color: Colors.white),
          ),
          pane: SearchPane()),
      SideBarItem(
          icon: const ResponsiveIcon(
            lightThemeIcon: Icon(Icons.bug_report),
            darkThemeIcon: Icon(Icons.bug_report, color: Colors.white),
          ),
          pane: DebugPane()),
      SideBarItem(
          icon: const ResponsiveIcon(
            lightThemeIcon: Icon(Icons.extension),
            darkThemeIcon: Icon(Icons.extension, color: Colors.white),
          ),
          pane: ExtensionsPane()),
    ],
  );
}();

final rightPaneData = PaneData(
  items: [
    SideBarItem(
        icon: const ResponsiveIcon(
          lightThemeIcon: Icon(Icons.toc),
          darkThemeIcon: Icon(Icons.toc, color: Colors.white),
        ),
        pane: OutlinePane()),
    SideBarItem(
        icon: const ResponsiveIcon(
          lightThemeIcon: Icon(Icons.timeline),
          darkThemeIcon: Icon(Icons.timeline, color: Colors.white),
        ),
        pane: TimelinePane()),
  ],
);
