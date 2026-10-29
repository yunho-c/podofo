export 'fractional_page_renderer_stub.dart'
    if (dart.library.io) 'fractional_page_renderer_native.dart';

/// Experimental main-view rasterization. Keep the ordinary path as the default
/// until native compositor, performance, and broader document coverage pass.
const fractionalPageRenderingEnabled = bool.fromEnvironment(
  'PODOFO_FRACTIONAL_RENDERING',
);

/// Refine the main viewport at every zoom after it stops changing. Independent
/// of the fractional transform flag so the harness can compare both effects.
const displayScaleRenderingEnabled = bool.fromEnvironment(
  'PODOFO_DISPLAY_SCALE_RENDERING',
);
