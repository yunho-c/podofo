import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:podofo_one/src/providers/providers.dart';
import 'package:podofo_one/src/providers/user_state_provider.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

class DebugPane extends ConsumerStatefulWidget {
  const DebugPane({super.key});

  @override
  ConsumerState<DebugPane> createState() => _DebugPaneState();
}

class _DebugPaneState extends ConsumerState<DebugPane> {
  SliderValue _value = const SliderValue.single(1.0);

  @override
  Widget build(BuildContext context) {
    final userState = ref.watch(userStateNotifierProvider);
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
                          value: _value,
                          onChanged: (value) {
                            setState(() {
                              _value = value;
                            });
                            ref
                                .read(shaderProvider.notifier)
                                .setUniform(value.value);
                          },
                        ),
                        Text(_value.value.toStringAsFixed(2)),
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
