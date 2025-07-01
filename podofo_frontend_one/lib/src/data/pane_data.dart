import 'package:flutter/material.dart';
import 'package:podofo_one/src/utils/responsive_icon.dart';

import 'package:podofo_one/src/widgets/areas/sidebar.dart';

import 'package:podofo_one/src/widgets/panes/ai_search_pane.dart';
import 'package:podofo_one/src/widgets/panes/annotation_pane.dart';
import 'package:podofo_one/src/widgets/panes/debug_pane.dart';
import 'package:podofo_one/src/widgets/panes/ai_chat_pane.dart';
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
        pane: ThumbnailPane(),
      ),
      SideBarItem(
        icon: const ResponsiveIcon(
          lightThemeIcon: Icon(Icons.density_medium),
          darkThemeIcon: Icon(Icons.density_medium, color: Colors.white),
        ),
        pane: OutlinePane(),
      ),
      SideBarItem(
        icon: const ResponsiveIcon(
          lightThemeIcon: Icon(Icons.comment_bank_outlined),
          darkThemeIcon: Icon(Icons.comment_bank_outlined, color: Colors.white),
        ),
        pane: AnnotationPane(),
      ),
      SideBarItem(
        icon: const ResponsiveIcon(
          lightThemeIcon: Icon(Icons.search),
          darkThemeIcon: Icon(Icons.search, color: Colors.white),
        ),
        pane: SearchPane(),
      ),
      SideBarItem(
        icon: const ResponsiveIcon(
          lightThemeIcon: Icon(Icons.android_outlined),
          darkThemeIcon: Icon(Icons.android_outlined, color: Colors.white),
        ),
        pane: AISearchPane(),
      ),
    ],
  );
}();

final rightPaneData = PaneData(
  items: [
    SideBarItem(
      icon: const ResponsiveIcon(
        lightThemeIcon: Icon(Icons.star_border_outlined),
        darkThemeIcon: Icon(Icons.star_border_outlined, color: Colors.white),
      ),
      pane: AIChatPane(),
    ),
    SideBarItem(
      icon: const ResponsiveIcon(
        lightThemeIcon: Icon(Icons.area_chart_outlined),
        darkThemeIcon: Icon(Icons.area_chart_outlined, color: Colors.white),
      ),
      pane: TimelinePane(),
    ),
    SideBarItem(
      icon: const ResponsiveIcon(
        lightThemeIcon: Icon(Icons.extension_outlined),
        darkThemeIcon: Icon(Icons.extension_outlined, color: Colors.white),
      ),
      pane: ExtensionsPane(),
    ),
    SideBarItem(
      icon: const ResponsiveIcon(
        lightThemeIcon: Icon(Icons.pest_control_outlined),
        darkThemeIcon: Icon(Icons.pest_control_outlined, color: Colors.white),
      ),
      pane: DebugPane(),
    ),
  ],
);
