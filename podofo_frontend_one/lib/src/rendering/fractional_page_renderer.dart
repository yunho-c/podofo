import 'fractional_page_renderer_stub.dart'
    if (dart.library.io) 'fractional_page_renderer_native.dart'
    as renderer;

export 'fractional_page_renderer_stub.dart'
    if (dart.library.io) 'fractional_page_renderer_native.dart';

/// Default on macOS. Explicit defines retain independent opt-outs for diagnosis
/// and controlled comparisons; unsupported renderers still use their fallback.
bool get fractionalPageRenderingEnabled =>
    const bool.hasEnvironment('PODOFO_FRACTIONAL_RENDERING')
    ? const bool.fromEnvironment('PODOFO_FRACTIONAL_RENDERING')
    : renderer.fractionalPageRenderingSupported;

/// Refine the main viewport at every zoom after it stops changing. Independent
/// of the fractional transform flag so the harness can compare both effects.
bool get displayScaleRenderingEnabled =>
    const bool.hasEnvironment('PODOFO_DISPLAY_SCALE_RENDERING')
    ? const bool.fromEnvironment('PODOFO_DISPLAY_SCALE_RENDERING')
    : renderer.fractionalPageRenderingSupported;
