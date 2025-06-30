import 'package:flutter/material.dart';

class ResponsiveIcon extends StatelessWidget {
  const ResponsiveIcon({
    super.key,
    required this.lightThemeIcon,
    required this.darkThemeIcon,
  });

  final Widget lightThemeIcon;
  final Widget darkThemeIcon;

  @override
  Widget build(BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    return isDarkMode ? darkThemeIcon : lightThemeIcon;
  }
}
