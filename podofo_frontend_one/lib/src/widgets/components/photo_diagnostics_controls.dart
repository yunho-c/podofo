import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import '../../dark_mode/photo_diagnostics.dart';
import '../../dark_mode/photo_quality.dart';
import '../../providers/document_provider.dart';
import '../../providers/photo_diagnostics_provider.dart';

class PhotoDiagnosticsControls extends ConsumerWidget {
  const PhotoDiagnosticsControls({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(showPhotoDiagnosticsProvider);
    final includeTranslucent = ref.watch(includeTranslucentPhotoPixelsProvider);
    final session = ref.watch(currentDocumentProvider)?.session;
    final quality = ref.watch(photoQualityProvider);
    void setQuality(PhotoQuality value) =>
        ref.read(photoQualityProvider.notifier).state = value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        Row(
          children: [
            const Expanded(child: Text('Show photo-preservation diagnostics')),
            Semantics(
              label: 'Show photo-preservation diagnostics',
              child: Switch(
                key: const ValueKey('photo-diagnostics-toggle'),
                value: enabled,
                onChanged: (value) =>
                    ref.read(showPhotoDiagnosticsProvider.notifier).state =
                        value,
              ),
            ),
          ],
        ),
        Row(
          children: [
            const Expanded(child: Text('Include translucent pixels')),
            Semantics(
              label: 'Include translucent pixels',
              child: Switch(
                key: const ValueKey('photo-translucent-toggle'),
                value: includeTranslucent,
                onChanged: (value) =>
                    ref
                            .read(
                              includeTranslucentPhotoPixelsProvider.notifier,
                            )
                            .state =
                        value,
              ),
            ),
          ],
        ),
        const Text(
          'Temporary preview: preserve nonzero alpha in the same eligible images. Requires dark mode and Preserve photos.',
        ).small(),
        _ResolutionChoices(
          label: 'Alpha-render scale',
          id: 'photo-alpha-scale',
          options: const [1, 2, 4],
          value: quality.alphaScale,
          suffix: '×',
          onChanged: (value) => setQuality(quality.copyWith(alphaScale: value)),
        ),
        _ResolutionChoices(
          label: 'Per-image mask',
          id: 'photo-coverage-size',
          options: const [256, 512, 1024],
          value: quality.coverageDimension,
          onChanged: (value) =>
              setQuality(quality.copyWith(coverageDimension: value)),
        ),
        _ResolutionChoices(
          label: 'Preservation texture',
          id: 'photo-texture-size',
          options: const [2048, 4096],
          value: quality.textureDimension,
          onChanged: (value) =>
              setQuality(quality.copyWith(textureDimension: value)),
        ),
        Text(
          'Temporary settings. Changing alpha or mask resolution reanalyzes visible pages. Coverage cache: up to ${quality.cachePages} pages within 64 MiB.',
        ).small(),
        GhostButton(
          key: const ValueKey('photo-quality-reset'),
          onPressed: () => setQuality(const PhotoQuality()),
          child: const Text('Reset resolutions'),
        ),
        if (enabled) ...[
          const Text(
            'Green: preserved · Orange: rejected · Gray: skipped or inactive',
          ).small(),
          const Text(
            'Works in light mode too. Images inside Forms are inspected. Object paths such as 4/2 identify nested children; numbers start at 0.',
          ).small(),
          if (session == null)
            const Text('Open a PDF to inspect its images.').small()
          else
            ValueListenableBuilder<PhotoDiagnosticsSnapshot?>(
              valueListenable: ref.watch(photoDiagnosticsProvider(session)),
              builder: (context, snapshot, _) {
                if (snapshot == null ||
                    snapshot.revision != session.revision ||
                    snapshot.pages.isEmpty) {
                  return const Text('Waiting for visible pages…').small();
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 8,
                  children: [
                    Text(
                      snapshot.textureWidth == null
                          ? 'Preservation texture: not ready or inactive'
                          : 'Preservation texture: ${snapshot.textureWidth} × ${snapshot.textureHeight}',
                    ).small(),
                    if (snapshot.omittedPages > 0)
                      Text(
                        '${snapshot.omittedPages} visible pages skipped: ${snapshot.pageCapacity}-page coverage-cache limit.',
                      ).small(),
                    for (final page in snapshot.pages) _PageDetails(page: page),
                  ],
                );
              },
            ),
        ],
      ],
    );
  }
}

class _PageDetails extends StatelessWidget {
  const _PageDetails({required this.page});
  final PhotoDiagnosticPage page;

  @override
  Widget build(BuildContext context) {
    final analysis = page.analysis;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 4,
      children: [
        Text('Page ${page.pageNumber}').small().semiBold(),
        if (analysis == null)
          const Text('Analysis pending…').small()
        else ...[
          if (analysis.totalImages > 0)
            Text(
              '${analysis.inspectedImages} of ${analysis.totalImages} images inspected'
              '${analysis.isComplete ? '' : '; ${analysis.pendingCount} pending'}',
            ).small(),
          if (analysis.fallback != null)
            Text('Page skipped: ${analysis.fallback}').small(),
          if (page.entries.isEmpty && analysis.fallback == null)
            const Text('No raster images found.').small(),
          if (analysis.omittedDiagnosticObjects > 0)
            Text(
              '${analysis.omittedDiagnosticObjects} additional object outlines omitted: diagnostic limit.',
            ).small(),
          for (final entry in page.entries)
            Collapsible(
              key: ValueKey('${page.pageNumber}-${entry.candidate.objectId}'),
              children: [
                CollapsibleTrigger(
                  child: Text('${entry.label} · ${entry.status.name}').small(),
                ),
                CollapsibleContent(child: _EntryDetails(entry: entry)),
              ],
            ),
        ],
      ],
    );
  }
}

class _EntryDetails extends StatelessWidget {
  const _EntryDetails({required this.entry});
  final PhotoDiagnosticEntry entry;

  @override
  Widget build(BuildContext context) {
    final stats = entry.candidate.classification;
    final coverage = entry.candidate.renderingCoverage(
      includeTranslucent: entry.includeTranslucent,
    );
    String percent(double value) => '${(value * 100).toStringAsFixed(1)}%';
    return Padding(
      padding: const EdgeInsets.only(left: 8, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(entry.reason).small(),
          if (entry.candidate.renderCoverage case final render?) ...[
            Text(
              'Alpha render: ${render.alphaWidth} × ${render.alphaHeight} (${render.alphaScale}×)',
            ).small(),
            Text(
              coverage == null || coverage.isFull
                  ? 'Coverage: opaque rectangle'
                  : 'Coverage: ${coverage.width} × ${coverage.height}',
            ).small(),
            if (render.limitation != null)
              Text('Resolution limited: ${render.limitation}').small(),
          ],
          if (coverage != null)
            Text(
              entry.includeTranslucent
                  ? 'Nonzero-alpha footprint: ${percent(coverage.fraction)}; transparent holes stay in dark mode.'
                  : 'Opaque footprint: ${percent(coverage.fraction)}; holes and translucent pixels stay in dark mode.',
            ).small(),
          if (entry.override != null)
            Text('Manual override; automatic result: ${entry.candidate.reason}')
                .small(),
          if (entry.candidate.reason == 'likely-photo')
            const Text('Photo classifier accepted this image.').small(),
          if (stats != null) ...[
            Text('Tonal entropy: ${stats.entropy.toStringAsFixed(2)} (min 4.5)')
                .small(),
            Text('Palette cells: ${stats.colors} (min 90)').small(),
            Text('Flat neighbors: ${percent(stats.flatFraction)} (max 45%)')
                .small(),
            Text('Sharp edges: ${percent(stats.edgeFraction)} (max 18%)')
                .small(),
            Text('Extreme tones: ${percent(stats.extremeFraction)} (max 30%)')
                .small(),
            Text(
              'Textured tiles: ${stats.texturedTiles}/16 (min ${stats.requiredTexturedTiles})',
            ).small(),
            if (entry.candidate.coverage != null)
              Text('Visible samples: ${stats.visibleSamples}/4096 (min 256)')
                  .small(),
            const Text(
              'Reason shows the first failed gate; multiple gates may fail.',
            ).small(),
          ] else
            const Text('Pixel classification was not reached.').small(),
        ],
      ),
    );
  }
}

class _ResolutionChoices extends StatelessWidget {
  const _ResolutionChoices({
    required this.label,
    required this.id,
    required this.options,
    required this.value,
    required this.onChanged,
    this.suffix = '',
  });
  final String label, id, suffix;
  final List<int> options;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    spacing: 4,
    children: [
      Text(label).small(),
      Row(
        spacing: 4,
        children: [
          for (final option in options)
            Expanded(
              child: Semantics(
                selected: value == option,
                label: '$label $option$suffix',
                child: Button(
                  key: ValueKey('$id-$option'),
                  style: value == option
                      ? const ButtonStyle.primary(size: ButtonSize.small)
                      : const ButtonStyle.outline(size: ButtonSize.small),
                  onPressed: () => onChanged(option),
                  child: Text('$option$suffix'),
                ),
              ),
            ),
        ],
      ),
    ],
  );
}
