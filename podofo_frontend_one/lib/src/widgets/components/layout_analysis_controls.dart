import 'dart:async';
import 'dart:io';
import 'dart:ffi';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import '../../providers/analysis_provider.dart';
import 'equation_controls.dart';
import 'model_overrides_controls.dart';

/// Deliberately in Developer mode until the selected model profile is promoted.
class LayoutAnalysisControls extends ConsumerWidget {
  const LayoutAnalysisControls({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!Platform.isMacOS || Abi.current() != Abi.macosArm64) {
      return const Text(
        'Layout analysis currently requires macOS on Apple Silicon.',
      );
    }
    final value = ref.watch(analysisControllerProvider);
    return value.when(
      loading: () => const Text('Opening analysis cache…'),
      error: (e, _) => Column(
        children: [
          Text('Analysis unavailable: $e'),
          Button(
            style: ButtonStyle.outline(),
            onPressed: () => ref.invalidate(analysisControllerProvider),
            child: const Text('Retry analysis cache'),
          ),
        ],
      ),
      data: (controller) => ListenableBuilder(
        listenable: controller,
        builder: (context, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Document analysis (experimental)'),
            const SizedBox(height: 8),
            Button(
              style: ButtonStyle.primary(),
              onPressed:
                  controller.canAnalyze &&
                      !controller.opening &&
                      !controller.running &&
                      controller.session != null
                  ? () => unawaited(controller.analyze())
                  : null,
              child: Text(
                controller.recognizesFormulas || controller.usingBundledModels
                    ? 'Analyze document and equations'
                    : 'Analyze document layout',
              ),
            ),
            if (controller.preparation case final preparation?)
              Text(preparation).small(),
            if (controller.running) ...[
              const SizedBox(height: 8),
              Button(
                style: ButtonStyle.outline(),
                onPressed: controller.cancel,
                child: const Text('Cancel analysis'),
              ),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                const Expanded(child: Text('Show layout regions')),
                Switch(
                  value: controller.showRegions,
                  onChanged: controller.toggleRegions,
                ),
              ],
            ),
            if (controller.progress case final progress?)
              Text(
                '${progress.processed.pagesFinished} / ${progress.processed.pagesTotal} pages finished',
              ).small(),
            if (controller.outcome case final outcome?)
              Text('Analysis ${outcome.status.name}').small(),
            if (controller.visiblePage case final page?)
              Text(
                '${page.regions.length} regions on this page · '
                '${controller.pageComplete ? 'complete' : 'partial'}',
              ).small(),
            if (controller.error case final error?) Text(error).small(),
            if (controller.recognizesFormulas) ...[
              const SizedBox(height: 16),
              const EquationControls(),
            ],
            const SizedBox(height: 12),
            const ModelOverridesControls(),
          ],
        ),
      ),
    );
  }
}
