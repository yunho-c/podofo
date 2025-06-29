import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart';

enum LeftPane { explorer, search, sourceControl, debug, extensions }

enum RightPane { outline, timeline }

final leftPaneProvider = StateProvider<LeftPane?>((ref) => LeftPane.explorer);
final rightPaneProvider = StateProvider<RightPane?>((ref) => null);

final commandPromptProvider = StateProvider<bool>((ref) => false);

final themeProvider = StateProvider<ThemeMode>((ref) => ThemeMode.dark);
