import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:podofo_one/src/providers/providers.dart';
import 'package:podofo_one/src/providers/user_state_provider.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

class DebugPane extends ConsumerWidget {
  const DebugPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final userState = ref.watch(userStateNotifierProvider);
    final shaderStrength = ref.watch(shaderStrengthProvider);
    return Container(
      padding: const EdgeInsets.all(10.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Collapsible(
              children: [
                const CollapsibleTrigger(child: Text('Dark Mode')),
                CollapsibleContent(
                  child: OutlinedContainer(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Inversion Shader Strength').small(),
                        gap(8),
                        Slider(
                          min: 0.0,
                          max: 1.0,
                          value: SliderValue.single(shaderStrength),
                          onChanged: (value) {
                            ref
                                .read(userPreferenceProvider.notifier)
                                .setShaderStrength(value.value);
                          },
                        ),
                        Text(shaderStrength.toStringAsFixed(2)),
                      ],
                    ).withPadding(horizontal: 16, vertical: 8),
                  ).withPadding(top: 8),
                ),
              ],
            ),
          ),
          Expanded(
            child: Collapsible(
              children: [
                const CollapsibleTrigger(child: Text('User State')),
                CollapsibleContent(
                  child: OutlinedContainer(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Highlight').small(),
                        Text('${userState.highlight}'),
                        Text('Appearance').small(),
                        Text('${userState.appearance}'),
                      ],
                    ).withPadding(horizontal: 16, vertical: 8),
                  ).withPadding(top: 8),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
