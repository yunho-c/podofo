import 'package:flutter/material.dart';

import 'package:podofo_one/src/widgets/areas/sidebar.dart';

import 'package:podofo_one/src/widgets/panes/debug_pane.dart';
import 'package:podofo_one/src/widgets/panes/explorer_pane.dart';
import 'package:podofo_one/src/widgets/panes/extensions_pane.dart';
import 'package:podofo_one/src/widgets/panes/outline_pane.dart';
import 'package:podofo_one/src/widgets/panes/search_pane.dart';
import 'package:podofo_one/src/widgets/panes/source_control_pane.dart';
import 'package:podofo_one/src/widgets/panes/timeline_pane.dart';

class PaneData {
  final List<SideBarItem> items;

  PaneData({required this.items});
}

final leftPaneData = () {
  return PaneData(
    items: [
      SideBarItem(icon: Icons.description, pane: ExplorerPane()),
      SideBarItem(icon: Icons.search, pane: SearchPane()),
      SideBarItem(icon: Icons.source, pane: SourceControlPane()),
      SideBarItem(icon: Icons.bug_report, pane: DebugPane()),
      SideBarItem(icon: Icons.extension, pane: ExtensionsPane()),
    ],
  );
}();

final rightPaneData = PaneData(
  items: [
    SideBarItem(icon: Icons.toc, pane: OutlinePane()),
    SideBarItem(icon: Icons.timeline, pane: TimelinePane()),
  ],
);
