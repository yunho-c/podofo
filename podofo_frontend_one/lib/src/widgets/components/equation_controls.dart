import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:podoco/podoco.dart' as podoco;
import 'package:shadcn_flutter/shadcn_flutter.dart';

import '../../analysis/equation_controller.dart';
import '../../providers/analysis_provider.dart';

/// Explicit region selection preserves the reader's text and annotation gestures.
class EquationControls extends ConsumerWidget {
  const EquationControls({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(equationControllerProvider);
    if (controller == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => _content(context, controller),
    );
  }

  Widget _content(BuildContext context, EquationController controller) {
    final page = controller.analysis.visiblePage;
    final selected = controller.selected;
    final formulas = page?.formulas ?? const <podoco.FormulaResult>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Equations on this page'),
        const SizedBox(height: 8),
        if (formulas.isEmpty)
          const Text('No equation detections available on this page.').small(),
        for (final (index, formula) in formulas.indexed) ...[
          Button(
            style: selected?.region.id == formula.regionId
                ? ButtonStyle.secondary()
                : ButtonStyle.outline(),
            onPressed: () => controller.select(formula.regionId),
            child: Text('Equation ${index + 1} · ${_status(formula.state)}'),
          ),
          const SizedBox(height: 6),
        ],
        if (selected != null) ...[
          Text(_detail(selected.state)).small(),
          if (selected.recognized case final formula?) ...[
            const SizedBox(height: 8),
            SelectableText(
              formula.latex,
              style: const TextStyle(fontFamily: 'monospace'),
            ),
            const SizedBox(height: 8),
            Button(
              style: ButtonStyle.outline(),
              onPressed: () => unawaited(controller.copyLatex()),
              child: const Text('Copy LaTeX'),
            ),
          ],
        ],
        const SizedBox(height: 12),
        if (controller.preparation case final preparation?)
          Text(preparation).small(),
        if (controller.canPrepareSpeech) ...[
          const SizedBox(height: 8),
          Text('Speech language: ${controller.narration.settings.language}')
              .small(),
          if (controller.ready && controller.availableStyles.isEmpty)
            const Text(
              'Math speech is unavailable in this language. Choose a supported language in the audio settings.',
            ).small(),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final style in controller.availableStyles)
                Button(
                  style: controller.speechStyle == style
                      ? ButtonStyle.secondary()
                      : ButtonStyle.outline(),
                  onPressed: () => controller.setSpeechStyle(style),
                  child: Text(style),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Button(
            style: ButtonStyle.primary(),
            onPressed:
                selected?.recognized != null &&
                    (!controller.ready ||
                        controller.availableStyles.contains(
                          controller.speechStyle,
                        )) &&
                    !controller.opening &&
                    !controller.speaking &&
                    controller.narration.available
                ? () => unawaited(controller.listen())
                : null,
            child: Text(
              controller.converting
                  ? 'Converting equation…'
                  : controller.speaking
                  ? 'Equation in audio player'
                  : 'Listen to equation',
            ),
          ),
          const Text(
            'Pause, stop, voice, and speed are available in the audio player.',
          ).small(),
        ],
        if (controller.lastSpeechText case final speech?) ...[
          const SizedBox(height: 8),
          const Text('Spoken text').small(),
          Text(speech).small(),
        ],
        for (final diagnostic in controller.diagnostics)
          Text(diagnostic).small(),
        if (controller.error case final error?)
          Text('Math speech: $error').small(),
      ],
    );
  }
}

String _status(podoco.FormulaState state) => switch (state) {
  podoco.FormulaPending() => 'pending',
  podoco.FormulaNotRequested() => 'not requested',
  podoco.FormulaFinishedState(:final outcome) => switch (outcome) {
    podoco.FormulaRecognized() => 'ready',
    podoco.FormulaTruncated() => 'incomplete',
    podoco.FormulaFailed() => 'failed',
  },
};

String _detail(podoco.FormulaState state) => switch (state) {
  podoco.FormulaPending() => 'Recognition is still pending.',
  podoco.FormulaNotRequested() =>
    'Recognition was not requested for this region.',
  podoco.FormulaFinishedState(:final outcome) => switch (outcome) {
    podoco.FormulaRecognized() =>
      'Review the recognized expression against the page before using it.',
    podoco.FormulaTruncated() => 'Recognition reached its length limit. Copy and Listen require a complete result.',
    podoco.FormulaFailed(:final error) => 'Recognition failed: $error',
  },
};
