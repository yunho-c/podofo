import 'package:flutter/services.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'package:podofo_one/src/providers/user_state_provider.dart';

class AudioReaderButton extends ConsumerStatefulWidget {
  const AudioReaderButton({super.key});

  @override
  ConsumerState<AudioReaderButton> createState() => _AudioReaderButtonState();
}

class _AudioReaderButtonState extends ConsumerState<AudioReaderButton> {
  bool _isPlaying = false;

  @override
  Widget build(BuildContext context) {
    final userState = ref.watch(userStateNotifierProvider);
    return GestureDetector(
      onTap: () {
        ref
            .read(userStateNotifierProvider.notifier)
            .setAudioReader(!userState.audioReader);
      },
      onSecondaryTapUp: (details) {
        showDropdown(
          context: context,
          position: details.globalPosition,
          builder: (context) {
            return SizedBox(
              width: 250,
              child: DropdownMenu(
                children: [
                  // MenuLabel(child: Text('Settings').xSmall.muted),
                  MenuButton(
                    // enabled: false,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        IconButton(
                          icon: const Icon(
                            FontAwesomeIcons.backwardFast,
                            size: 16,
                          ),
                          onPressed: () {},
                          variance: ButtonStyle.ghostIcon(),
                        ),
                        IconButton(
                          icon: const Icon(
                            FontAwesomeIcons.backwardStep,
                            size: 16,
                          ),
                          onPressed: () {},
                          variance: ButtonStyle.ghostIcon(),
                        ),
                        IconButton(
                          icon: Icon(
                            _isPlaying
                                ? FontAwesomeIcons.pause
                                : FontAwesomeIcons.play,
                            size: 16,
                          ),
                          onPressed: () {
                            setState(() {
                              _isPlaying = !_isPlaying;
                            });
                          },
                          variance: ButtonStyle.ghostIcon(),
                        ),
                        IconButton(
                          icon: const Icon(
                            FontAwesomeIcons.forwardStep,
                            size: 16,
                          ),
                          onPressed: () {},
                          variance: ButtonStyle.ghostIcon(),
                        ),
                        IconButton(
                          icon: const Icon(
                            FontAwesomeIcons.forwardFast,
                            size: 16,
                          ),
                          onPressed: () {},
                          variance: ButtonStyle.ghostIcon(),
                        ),
                      ],
                    ),
                  ),
                  MenuLabel(
                    child: Text('Speed:').small.normal,
                    trailing: Text(
                      (userState.audioSpeed).toStringAsFixed(2),
                    ).small.semiBold,
                  ),
                  MenuButton(
                    child: Slider(
                      min: 0.5,
                      max: 2.0,
                      value: SliderValue.single(userState.audioSpeed),
                      onChanged: (value) {
                        ref
                            .read(userStateNotifierProvider.notifier)
                            .setAudioSpeed(value.value);
                      },
                    ),
                  ),
                  MenuDivider(),
                  MenuButton(
                    child: Text('Download as ...'),
                    subMenu: [
                      MenuButton(child: Text("mp3")),
                      MenuButton(child: Text("ogg")),
                    ],
                  ),
                  MenuDivider(),
                  MenuLabel(child: Text('Settings').xSmall.medium.muted),
                  MenuButton(
                    child: Text('Use keyboard to play/pause'),
                    trailing: Switch(
                      value: userState.useKeyboardShortcutsToPlayPause,
                      onChanged: (value) {
                        ref
                            .read(userStateNotifierProvider.notifier)
                            .setUseKeyboardShortcutsToPlayPause(value);
                      },
                    ),
                  ),
                  MenuButton(
                    child: Text('Cmd-click to read'),
                    trailing: Switch(
                      value: userState.commandClickToReadSentence,
                      onChanged: (value) {
                        ref
                            .read(userStateNotifierProvider.notifier)
                            .setCommandClickToReadSentence(value);
                      },
                    ),
                  ),
                  MenuButton(subMenu: [], child: Text('Voices')),
                  MenuButton(
                    subMenu: [
                      MenuButton(
                        child: Text('System'),
                        onPressed: (context) {
                          ref
                              .read(userStateNotifierProvider.notifier)
                              .setAudioBackend('system');
                        },
                      ),
                      MenuButton(
                        child: Text('ONNX Runtime'),
                        onPressed: (context) {
                          ref
                              .read(userStateNotifierProvider.notifier)
                              .setAudioBackend('ONNX Runtime');
                        },
                      ),
                      MenuButton(
                        child: Text('TVM'),
                        onPressed: (context) {
                          ref
                              .read(userStateNotifierProvider.notifier)
                              .setAudioBackend('TVM');
                        },
                      ),
                      MenuButton(
                        child: Text('Candle'),
                        onPressed: (context) {
                          ref
                              .read(userStateNotifierProvider.notifier)
                              .setAudioBackend('Candle');
                        },
                      ),
                    ],
                    child: Text('Backends'),
                  ),
                ],
              ),
            );
          },
        );
      },
      child: IconButton(
        icon: Icon(
          _isPlaying ? BootstrapIcons.headphones : BootstrapIcons.activity,
        ),
        onPressed: () {
          setState(() {
            _isPlaying = !_isPlaying;
          });
        },
        variance: ButtonStyle.ghostIcon(),
      ),
    );
  }
}
