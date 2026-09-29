import 'package:flutter_riverpod/legacy.dart';

import 'package:podofo_one/src/widgets/areas/sidebar.dart';

final leftPaneProvider = StateProvider<SideBarItem?>((ref) => null);
final rightPaneProvider = StateProvider<SideBarItem?>((ref) => null);
final commandPaletteProvider = StateProvider<bool>((ref) => false);
