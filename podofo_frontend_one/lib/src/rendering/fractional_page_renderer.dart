export 'fractional_page_renderer_stub.dart'
    if (dart.library.io) 'fractional_page_renderer_native.dart';

/// Experimental main-view rasterization. Keep the ordinary path as the default
/// until native compositor, performance, and broader document coverage pass.
const fractionalPageRenderingEnabled = bool.fromEnvironment(
  'PODOFO_FRACTIONAL_RENDERING',
);
