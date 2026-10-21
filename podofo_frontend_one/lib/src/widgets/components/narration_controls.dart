import 'dart:async';

import 'package:flutter/material.dart' as m;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import '../../narration/narrator.dart';
import 'document_narration_timeline.dart';
import '../../narration/paper_sequence.dart';
import '../../providers/narration_provider.dart';
import '../../providers/user_state_provider.dart';
import '../../services/narration_actions.dart';

class NarrationControls extends ConsumerWidget {
  const NarrationControls({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(narrationControllerProvider);
    final developerMode = ref.watch(
      userStateNotifierProvider.select((state) => state.developerMode),
    );
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (controller.source == null &&
            !controller.preparing &&
            controller.error == null) {
          return const SizedBox.shrink();
        }
        final state = controller.snapshot;
        final total = state?.durationFrames ?? state?.estimatedFrames;
        final voice = controller.voices
            .where((v) => v.id == controller.settings.voice)
            .firstOrNull;
        final languages =
            (voice?.languages ??
                    controller.voices.expand((v) => v.languages).toSet())
                .toList()
              ..sort();
        final canNavigate = controller.sentences.isNotEmpty;
        final sequence = controller.source?.sequence;
        final paper = sequence is PaperSequence ? sequence : null;
        Widget button(
          String name,
          IconData icon,
          VoidCallback? action, {
          String? key,
        }) => m.Tooltip(
          message: name,
          child: IconButton(
            key: key == null ? null : ValueKey(key),
            icon: Icon(icon),
            variance: ButtonStyle.ghostIcon(),
            onPressed: action,
          ),
        );
        void configure({String? voiceId, String? language, double? speed}) {
          final next = NarrationSettings(
            voice: voiceId ?? controller.settings.voice,
            language: language ?? controller.settings.language,
            speed: speed ?? controller.settings.speed,
          );
          final preferences = ref.read(userStateNotifierProvider.notifier);
          preferences.setAudioVoice(next.voice);
          preferences.setAudioSpeed(next.speed);
          preferences.setAudioLanguage(next.language);
          unawaited(controller.configure(next));
        }

        return Container(
          key: const ValueKey('narration-controls'),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.background,
            border: Border(
              top: BorderSide(color: Theme.of(context).colorScheme.border),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  if (controller.preparing)
                    const Padding(
                      padding: EdgeInsets.only(right: 12),
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(),
                      ),
                    ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          controller.source?.title ?? 'Listen to your paper',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ).small(),
                        Text(
                          controller.status,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ).small().muted(),
                      ],
                    ),
                  ),
                  button(
                    'Previous sentence',
                    m.Icons.skip_previous_rounded,
                    canNavigate || sequence != null
                        ? () => controller.navigate(forward: false)
                        : null,
                    key: 'narration-previous',
                  ),
                  button(
                    controller.paused || controller.terminal ? 'Play' : 'Pause',
                    controller.paused || controller.terminal
                        ? m.Icons.play_arrow_rounded
                        : m.Icons.pause_rounded,
                    controller.source != null || controller.preparing
                        ? controller.togglePause
                        : null,
                    key: 'narration-play-pause',
                  ),
                  button(
                    'Next sentence',
                    m.Icons.skip_next_rounded,
                    canNavigate || sequence != null
                        ? () => controller.navigate(forward: true)
                        : null,
                    key: 'narration-next',
                  ),
                  button(
                    'Stop reading',
                    m.Icons.stop_rounded,
                    controller.active ? controller.stop : null,
                    key: 'narration-stop',
                  ),
                ],
              ),
              if (controller.voices.isNotEmpty)
                Row(
                  children: [
                    m.PopupMenuButton<String>(
                      tooltip: 'Voice',
                      onSelected: (value) => configure(voiceId: value),
                      itemBuilder: (_) => [
                        const m.PopupMenuItem(
                          value: '',
                          child: Text('Automatic voice'),
                        ),
                        for (final voice in controller.voices)
                          m.PopupMenuItem(
                            value: voice.id,
                            child: Text(voice.name),
                          ),
                      ],
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Text(voice?.name ?? 'Automatic voice').small(),
                      ),
                    ),
                    m.PopupMenuButton<String>(
                      tooltip: 'Speech language',
                      onSelected: (value) => configure(language: value),
                      itemBuilder: (_) => [
                        for (final code in languages)
                          m.PopupMenuItem(
                            value: code,
                            child: Text(code.toUpperCase()),
                          ),
                      ],
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Text(controller.settings.language.toUpperCase())
                            .small(),
                      ),
                    ),
                    m.PopupMenuButton<double>(
                      tooltip: 'Speaking speed',
                      onSelected: (value) => configure(speed: value),
                      itemBuilder: (_) => [
                        for (final speed in narrationSpeeds)
                          m.PopupMenuItem(
                            value: speed,
                            child: Text('${speed.toStringAsFixed(1)}×'),
                          ),
                      ],
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Text(
                          '${controller.settings.speed.toStringAsFixed(1)}×',
                        ).small(),
                      ),
                    ),
                    const Spacer(),
                    button(
                      'Show reading location',
                      m.Icons.my_location,
                      controller.source?.passage != null
                          ? () => NarrationActions.showSource(ref)
                          : null,
                    ),
                    button(
                      controller.followText
                          ? 'Stop following text'
                          : 'Follow spoken text',
                      controller.followText
                          ? m.Icons.visibility
                          : m.Icons.visibility_off,
                      () {
                        final value = !controller.followText;
                        ref
                            .read(userStateNotifierProvider.notifier)
                            .setFollowSpokenText(value);
                        controller.setFollowText(value);
                      },
                    ),
                  ],
                ),
              if (paper != null)
                Row(
                  children: [
                    Text('Page ${paper.pageNumber} of ${paper.pageCount}')
                        .small()
                        .muted(),
                    const Spacer(),
                    if (paper.review != null) ...[
                      m.TextButton(
                        onPressed: () {
                          NarrationActions.showSource(ref);
                          NarrationActions.readPaper(
                            ref,
                            page: paper.review!.page.page,
                            options: paper.options,
                          );
                        },
                        child: const Text('Review page'),
                      ),
                      m.TextButton(
                        onPressed: () {
                          paper.skipReview();
                          controller.movePassage(1);
                        },
                        child: const Text('Skip this page'),
                      ),
                    ] else ...[
                      m.TextButton(
                        onPressed: controller.preparing
                            ? null
                            : () => controller.movePassage(-1),
                        child: const Text('Previous passage'),
                      ),
                      m.TextButton(
                        onPressed: controller.preparing
                            ? null
                            : () => controller.movePassage(1),
                        child: const Text('Next passage'),
                      ),
                    ],
                  ],
                ),
              if (paper != null)
                DocumentNarrationTimeline(
                  controller: controller,
                  developerMode: developerMode,
                ),
              if ((paper == null ||
                      controller.documentTimeline?.totalMicroseconds == null) &&
                  state != null &&
                  total != null &&
                  total > 0)
                Row(
                  children: [
                    Text(_clock(state.positionFrames, state.sampleRate))
                        .small()
                        .muted(),
                    Expanded(
                      child: m.Slider(
                        key: const ValueKey('narration-timeline'),
                        value: state.positionFrames.clamp(0, total).toDouble(),
                        max: total.toDouble(),
                        label:
                            'Passage ${_clock(state.positionFrames, state.sampleRate)}',
                        onChanged: controller.active
                            ? (value) => controller.seek(value.round())
                            : null,
                      ),
                    ),
                    Text(
                      '${state.durationFrames == null ? '~' : ''}${_clock(total, state.sampleRate)} · passage',
                    ).small().muted(),
                  ],
                ),
            ],
          ),
        );
      },
    );
  }
}

String _clock(int frames, int rate) {
  final seconds = frames ~/ rate;
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}
