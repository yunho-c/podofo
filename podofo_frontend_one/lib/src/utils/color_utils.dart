import 'dart:ui';

String colorToHex(Color color) {
  // #AARRGGBB
  return '#${color.toARGB32().toRadixString(16).padLeft(8, '0')}';
}

Color colorFromHex(String hexString) {
  final buffer = StringBuffer();
  if (hexString.length == 6 || hexString.length == 7) buffer.write('ff');
  buffer.write(hexString.replaceFirst('#', ''));
  return Color(int.parse(buffer.toString(), radix: 16));
}
