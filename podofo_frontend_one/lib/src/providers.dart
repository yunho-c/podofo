import 'package:flutter_riverpod/flutter_riverpod.dart';

enum SidePane { explorer, search, sourceControl, debug, extensions }

enum RightSidePane { outline, timeline }

final sidePaneProvider = StateProvider<SidePane?>((ref) => SidePane.explorer);
final rightSidePaneProvider = StateProvider<RightSidePane?>((ref) => null);

final commandPromptProvider = StateProvider<bool>((ref) => false);
