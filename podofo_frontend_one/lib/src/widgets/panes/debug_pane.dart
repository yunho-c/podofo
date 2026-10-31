import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:podofo_one/src/providers/document_provider.dart';
import 'package:podofo_one/src/providers/user_state_provider.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import '../../services/context_menu_trace.dart';
import '../components/layout_analysis_controls.dart';

class DebugPane extends ConsumerWidget {
  const DebugPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final userState = ref.watch(userStateNotifierProvider);
    final loadedDocuments = ref.watch(loadedDocumentsProvider);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(10.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(child: Text('Developer mode')),
              Semantics(
                label: 'Developer mode',
                child: Switch(
                  value: userState.developerMode,
                  onChanged: (value) => ref
                      .read(userStateNotifierProvider.notifier)
                      .setDeveloperMode(value),
                ),
              ),
            ],
          ),
          if (userState.developerMode) ...[
            const SizedBox(height: 16),
            const LayoutAnalysisControls(),
          ],
          const SizedBox(height: 16),
          const _PdfRenderingStatus(),
          const SizedBox(height: 16),
          const _ContextMenuDiagnostics(),
          const SizedBox(height: 16),
          Collapsible(
            children: [
              const CollapsibleTrigger(child: Text('Loaded Documents')),
              CollapsibleContent(
                child: OutlinedContainer(
                  child: Column(
                    children: [
                      for (final doc in loadedDocuments.values)
                        Text('${doc.title}: ${doc.lastOpenedPage ?? 'Not set'}')
                            .small(),
                    ],
                  ).withPadding(horizontal: 16, vertical: 8),
                ).withPadding(top: 8),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Collapsible(
            children: [
              const CollapsibleTrigger(child: Text('Dark Mode')),
              CollapsibleContent(
                child: OutlinedContainer(
                  child: Column(children: [])
                      .withPadding(horizontal: 16, vertical: 8),
                ).withPadding(top: 8),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Collapsible(
            children: [
              const CollapsibleTrigger(child: Text('User State')),
              CollapsibleContent(
                child: OutlinedContainer(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Selected Text').small(),
                      Text(
                        '${userState.selectedText}',
                        maxLines: 5,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text('Highlight Mode Enabled').small(),
                      Text('${userState.highlightModeEnabled}'),
                      Text('Highlight Active Color Index').small(),
                      Text('${userState.highlightActiveColorIndex}'),
                      Text('Appearance').small(),
                      Text(userState.appearance),
                      const SizedBox(height: 10),
                      Button(
                        style: ButtonStyle.ghost(),
                        onPressed: () {
                          ref.read(userStateNotifierProvider.notifier).nuke();
                        },
                        child: const Text('Nuke User State'),
                      ),
                    ],
                  ).withPadding(horizontal: 16, vertical: 8),
                ).withPadding(top: 8),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PdfRenderingStatus extends ConsumerWidget {
  const _PdfRenderingStatus();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final document = ref.watch(currentDocumentProvider);
    final controller = ref.watch(pdfViewerControllerProvider);
    return OutlinedContainer(
      child: ValueListenableBuilder<List<PdfPageRenderingStatus>>(
        valueListenable: controller.renderingStatus,
        builder: (context, pages, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Reduced-DPI cache').small().semiBold(),
            if (document != null &&
                controller.isReady &&
                controller.params.renderAtDisplayScale)
              const Text('Refine at every settled display scale')
                  .small()
                  .muted(),
            const SizedBox(height: 8),
            if (document == null)
              const Text('No document loaded').small()
            else if (pages.isEmpty)
              const Text('Waiting for page render…').small()
            else
              for (final page in pages)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Page ${page.pageNumber}: ${switch (page.mode) {
                          PdfPageRenderMode.loading => 'Loading…',
                          PdfPageRenderMode.preview => 'Active',
                          PdfPageRenderMode.refining => 'Refining…',
                          PdfPageRenderMode.fullResolution => 'Inactive',
                        }}',
                      ).small(),
                      Text(switch (page.mode) {
                        PdfPageRenderMode.loading => 'Waiting for a bitmap',
                        PdfPageRenderMode.preview => 'Using cached page image',
                        PdfPageRenderMode.refining =>
                          'Cached image; display render pending',
                        PdfPageRenderMode.fullResolution =>
                          'Using display-resolution image',
                      }).small().muted(),
                      Text(
                        '${(page.previewScale * 72).toStringAsFixed(0)} DPI cache · '
                        '${(page.targetScale * 72).toStringAsFixed(0)} DPI target',
                      ).small().muted(),
                      if (page.usesFractionalTransform)
                        const Text('Fractional transform prototype')
                            .small()
                            .muted(),
                    ],
                  ),
                ),
          ],
        ),
      ).withPadding(horizontal: 12, vertical: 10),
    );
  }
}

class _ContextMenuDiagnostics extends ConsumerWidget {
  const _ContextMenuDiagnostics();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trace = ref.read(contextMenuTraceProvider);
    return ListenableBuilder(
      listenable: trace,
      builder: (context, _) => OutlinedContainer(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(child: Text('Trace right-clicks')),
                Semantics(
                  label: 'Trace right-clicks',
                  child: Switch(
                    value: trace.enabled,
                    onChanged: (value) => trace.enabled = value,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text('Enable, reproduce a missed click, then copy the trace.')
                .small(),
            Text(
              '${trace.length} events · ${trace.dropped} older events dropped',
            ).small().muted(),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                Button(
                  style: ButtonStyle.outline(),
                  onPressed: trace.length == 0
                      ? null
                      : () => Clipboard.setData(
                          ClipboardData(text: trace.export()),
                        ),
                  child: const Text('Copy trace'),
                ),
                Button(
                  style: ButtonStyle.outline(),
                  onPressed: trace.length == 0 ? null : trace.clear,
                  child: const Text('Clear trace'),
                ),
              ],
            ),
          ],
        ).withPadding(horizontal: 12, vertical: 10),
      ),
    );
  }
}
