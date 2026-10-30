import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import '../../dark_mode/photo_diagnostics.dart';
import '../../providers/document_provider.dart';
import '../../providers/photo_diagnostics_provider.dart';

class PhotoDiagnosticsControls extends ConsumerWidget {
  const PhotoDiagnosticsControls({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(showPhotoDiagnosticsProvider);
    final session = ref.watch(currentDocumentProvider)?.session;
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
                    if (snapshot.omittedPages > 0)
                      Text(
                        '${snapshot.omittedPages} visible pages skipped: 64-page analysis limit.',
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
    String percent(double value) => '${(value * 100).toStringAsFixed(1)}%';
    return Padding(
      padding: const EdgeInsets.only(left: 8, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(entry.reason).small(),
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
            Text('Textured tiles: ${stats.texturedTiles}/16 (min 10)').small(),
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
