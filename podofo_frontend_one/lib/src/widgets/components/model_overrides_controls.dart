import 'package:file_selector/file_selector.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import '../../providers/analysis_provider.dart';

/// Session-local diagnostics. Normal analysis resolves immutable app resources.
class ModelOverridesControls extends ConsumerWidget {
  const ModelOverridesControls({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final analysis = ref.watch(analysisControllerProvider).asData?.value;
    final equations = ref.watch(equationControllerProvider);
    if (analysis == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: Listenable.merge([analysis, ?equations]),
      builder: (context, _) {
        final busy =
            analysis.opening ||
            analysis.running ||
            (equations?.opening ?? false);
        return Collapsible(
          children: [
            const CollapsibleTrigger(child: Text('Model overrides')),
            CollapsibleContent(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    analysis.usingBundledModels
                        ? 'Using bundled analysis models.'
                        : 'Using custom analysis models for this session.',
                  ).small(),
                  Button(
                    style: ButtonStyle.outline(),
                    onPressed: busy
                        ? null
                        : () async {
                            final path = await getDirectoryPath(
                              confirmButtonText: 'Open layout model',
                            );
                            if (path != null && context.mounted) {
                              await analysis.configure(
                                path,
                                formulaDirectory: analysis.modelPaths?.formula,
                              );
                            }
                          },
                    child: const Text('Open layout model…'),
                  ),
                  const SizedBox(height: 6),
                  Button(
                    style: ButtonStyle.outline(),
                    onPressed: busy || analysis.modelPaths == null
                        ? null
                        : () async {
                            final path = await getDirectoryPath(
                              confirmButtonText: 'Open formula model',
                            );
                            if (path != null && context.mounted) {
                              await analysis.configure(
                                analysis.modelPaths!.layout,
                                formulaDirectory: path,
                              );
                            }
                          },
                    child: const Text('Open formula model…'),
                  ),
                  const SizedBox(height: 6),
                  Button(
                    style: ButtonStyle.outline(),
                    onPressed: busy || equations == null
                        ? null
                        : () async {
                            final path = await getDirectoryPath(
                              confirmButtonText: 'Open math speech rules',
                            );
                            if (path != null && context.mounted) {
                              await equations.configureRules(path);
                            }
                          },
                    child: const Text('Open math speech rules…'),
                  ),
                  const SizedBox(height: 6),
                  Button(
                    style: ButtonStyle.outline(),
                    onPressed: busy || !analysis.hasBundledModels
                        ? null
                        : () async {
                            if (equations?.hasBundledRules ?? false) {
                              await equations!.useBundledRules();
                            }
                            await analysis.useBundledModels();
                          },
                    child: const Text('Use bundled models'),
                  ),
                ],
              ).withPadding(top: 8),
            ),
          ],
        );
      },
    );
  }
}
