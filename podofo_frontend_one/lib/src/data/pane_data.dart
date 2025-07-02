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
        name: 'Thumbnails',
        icon: const ResponsiveIcon(
          lightThemeIcon: Icon(Icons.grid_view),
          darkThemeIcon: Icon(Icons.grid_view, color: Colors.white),
        ),
        pane: const ThumbnailPane(),
      ),
      SideBarItem(
        name: 'Outline',
        icon: const ResponsiveIcon(
          lightThemeIcon: Icon(Icons.density_medium),
          darkThemeIcon: Icon(Icons.density_medium, color: Colors.white),
        ),
        pane: const OutlinePane(),
      ),
      SideBarItem(
        name: 'Annotations',
        icon: const ResponsiveIcon(
          lightThemeIcon: Icon(Icons.comment_bank_outlined),
          darkThemeIcon: Icon(Icons.comment_bank_outlined, color: Colors.white),
        ),
        pane: const AnnotationPane(),
      ),
      SideBarItem(
        name: 'Search',
        icon: const ResponsiveIcon(
          lightThemeIcon: Icon(Icons.search),
          darkThemeIcon: Icon(Icons.search, color: Colors.white),
        ),
        pane: const SearchPane(),
      ),
      SideBarItem(
        name: 'AI Search',
        icon: const ResponsiveIcon(
          lightThemeIcon: Icon(Icons.android_outlined),
          darkThemeIcon: Icon(Icons.android_outlined, color: Colors.white),
        ),
        pane: const AISearchPane(),
      ),
    ],
  );
}();

final rightPaneData = PaneData(
  items: [
    SideBarItem(
      name: 'AI Chat',
      icon: const ResponsiveIcon(
        lightThemeIcon: Icon(Icons.star_border_outlined),
        darkThemeIcon: Icon(Icons.star_border_outlined, color: Colors.white),
      ),
      pane: const AIChatPane(),
    ),
    SideBarItem(
      name: 'Timeline',
      icon: const ResponsiveIcon(
        lightThemeIcon: Icon(Icons.area_chart_outlined),
        darkThemeIcon: Icon(Icons.area_chart_outlined, color: Colors.white),
      ),
      pane: const TimelinePane(),
    ),
    SideBarItem(
      name: 'Extensions',
      icon: const ResponsiveIcon(
        lightThemeIcon: Icon(Icons.extension_outlined),
        darkThemeIcon: Icon(Icons.extension_outlined, color: Colors.white),
      ),
      pane: const ExtensionsPane(),
    ),
    SideBarItem(
      name: 'Debug',
      icon: const ResponsiveIcon(
        lightThemeIcon: Icon(Icons.pest_control_outlined),
        darkThemeIcon: Icon(Icons.pest_control_outlined, color: Colors.white),
      ),
      pane: const DebugPane(),
    ),
  ],
);
