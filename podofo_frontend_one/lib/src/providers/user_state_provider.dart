import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:objectbox/objectbox.dart';

import 'data_provider.dart';

@Entity()
class UserState {
  @Id()
  int id = 0;
  String appearance = 'light';
  bool highlightModeEnabled = false;
  String? highlightColor;
  int highlightActiveColorIndex = 0;
  List<String> highlightColorPalette = [];
  String? previousPosition;
  String? selectedText;
  bool audioReader = false;
  bool useKeyboardShortcutsToPlayPause = false;
  bool commandClickToReadSentence = false;
  String audioBackend = 'system';
  String? audioVoice;
  double audioSpeed = 1.0;
  String audioLanguage = 'en';
  bool followSpokenText = true;
  @Property(uid: 8031658732022810243)
  bool autoSaveEnabled = true;
  UserState();
  UserState.from(UserState other)
    : id = other.id,
      appearance = other.appearance,
      highlightModeEnabled = other.highlightModeEnabled,
      highlightColor = other.highlightColor,
      highlightActiveColorIndex = other.highlightActiveColorIndex,
      highlightColorPalette = List.of(other.highlightColorPalette),
      previousPosition = other.previousPosition,
      selectedText = other.selectedText,
      audioReader = other.audioReader,
      useKeyboardShortcutsToPlayPause = other.useKeyboardShortcutsToPlayPause,
      commandClickToReadSentence = other.commandClickToReadSentence,
      audioBackend = other.audioBackend,
      audioVoice = other.audioVoice,
      audioSpeed = other.audioSpeed,
      audioLanguage = other.audioLanguage,
      followSpokenText = other.followSpokenText,
      autoSaveEnabled = other.autoSaveEnabled;
}

final userStateNotifierProvider =
    NotifierProvider<UserStateNotifier, UserState>(UserStateNotifier.new);

class UserStateNotifier extends Notifier<UserState> {
  late Box<UserState> _box;
  @override
  UserState build() {
    _box = ref.watch(objectboxProvider).store.box<UserState>();
    final result = _box.get(1) ?? _box.getAll().firstOrNull ?? UserState();
    if (result.audioLanguage.isEmpty) result.audioLanguage = 'en';
    final valid = result.highlightColorPalette
        .where((color) => RegExp(r'^#[0-9a-fA-F]{8}$').hasMatch(color))
        .toList();
    result.highlightColorPalette = valid.isEmpty
        ? [
            '#66f44336',
            '#66ff9800',
            '#66ffeb3b',
            '#664caf50',
            '#6600bcd4',
            '#663f51b5',
          ]
        : valid;
    result.highlightActiveColorIndex = result.highlightActiveColorIndex.clamp(
      0,
      result.highlightColorPalette.length - 1,
    );
    if (result.highlightColor == null ||
        !RegExp(r'^#[0-9a-fA-F]{8}$').hasMatch(result.highlightColor!)) {
      result.highlightColor =
          result.highlightColorPalette[result.highlightActiveColorIndex];
    }
    result.selectedText = null;
    _box.put(result);
    return result;
  }

  void _update(void Function(UserState) change) {
    final next = UserState.from(state);
    change(next);
    _box.put(next);
    state = next;
  }

  void updateSelectedText(String? text) {
    state = UserState.from(state)..selectedText = text;
  }

  void setHighlightActiveColorIndex(int index) {
    if (index < 0 || index >= state.highlightColorPalette.length) return;
    _update(
      (s) => s
        ..highlightActiveColorIndex = index
        ..highlightColor = s.highlightColorPalette[index],
    );
  }

  void setHighlightColorPalette(List<String> colors) {
    if (colors.isEmpty ||
        colors.any((c) => !RegExp(r'^#[0-9a-fA-F]{8}$').hasMatch(c))) {
      return;
    }
    _update(
      (s) => s
        ..highlightColorPalette = List.of(colors)
        ..highlightActiveColorIndex = 0
        ..highlightColor = colors.first,
    );
  }

  void setAppearance(String value) => _update((s) => s.appearance = value);
  void setHighlightModeEnabled(bool value) =>
      _update((s) => s.highlightModeEnabled = value);
  void setHighlightColor(String? value) =>
      _update((s) => s.highlightColor = value);
  void setPreviousPosition(String? value) =>
      _update((s) => s.previousPosition = value);
  void setAudioReader(bool value) => _update((s) => s.audioReader = value);
  void setUseKeyboardShortcutsToPlayPause(bool value) =>
      _update((s) => s.useKeyboardShortcutsToPlayPause = value);
  void setCommandClickToReadSentence(bool value) =>
      _update((s) => s.commandClickToReadSentence = value);
  void setAudioBackend(String value) => _update((s) => s.audioBackend = value);
  void setAudioVoice(String? value) => _update((s) => s.audioVoice = value);
  void setAudioSpeed(double value) => _update((s) => s.audioSpeed = value);
  void setAudioLanguage(String value) =>
      _update((s) => s.audioLanguage = value);
  void setFollowSpokenText(bool value) =>
      _update((s) => s.followSpokenText = value);
  void setAutoSaveEnabled(bool value) =>
      _update((s) => s.autoSaveEnabled = value);
  void nuke() {
    _box.remove(state.id);
    ref.invalidateSelf();
  }
}
