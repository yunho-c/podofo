import 'package:flutter/material.dart';

const ColorFilter _differenceDarkModeColorFilter = ColorFilter.mode(
  Colors.white,
  BlendMode.difference,
);

const ColorFilter _luminosityDarkModeColorFilter = ColorFilter.matrix(<double>[
  // R G  B  A  Const
  -0.2126, -0.7152, -0.0722, 0, 255, // Red channel
  -0.2126, -0.7152, -0.0722, 0, 255, // Green channel
  -0.2126, -0.7152, -0.0722, 0, 255, // Blue channel
  0, 0, 0, 1, 0, // Alpha channel
]);

/// A color matrix that approximates a hue-preserving color inversion.
///
/// This matrix is a heuristic based on the common CSS filter combination
/// `invert(1) hue-rotate(180deg)`. It is not as accurate as a full
/// HSL-based conversion (like the shader method) but is much simpler
/// to implement and works well for many use cases.
///
/// It correctly inverts luminance (black <-> white) while making a
/// strong attempt to return colors to their original hue.
const ColorFilter _heuristicDarkModeColorFilter = ColorFilter.matrix(<double>[
  // R     G     B     A  Const
  -0.574, 1.430, 0.144, 0, 0, // Red channel
  0.426, -0.430, 0.144, 0, 0, // Green channel
  0.426, 1.430, -0.856, 0, 0, // Blue channel
  0, 0, 0, 1, 0, // Alpha channel
]);
