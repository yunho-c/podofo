import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:objectbox/objectbox.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:podofo_one/src/providers/data_provider.dart';
import 'package:podofo_one/src/utils/color_utils.dart';

part 'user_state_provider.g.dart';

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

  bool autoSaveEnabled = true;

  UserState();

  UserState.from(UserState other)
    : id = other.id,
      appearance = other.appearance,
      highlightModeEnabled = other.highlightModeEnabled,
      highlightColor = other.highlightColor,
      highlightActiveColorIndex = other.highlightActiveColorIndex,
      highlightColorPalette = other.highlightColorPalette,
      previousPosition = other.previousPosition,
      selectedText = other.selectedText,
      audioReader = other.audioReader,
      useKeyboardShortcutsToPlayPause = other.useKeyboardShortcutsToPlayPause,
      commandClickToReadSentence = other.commandClickToReadSentence,
      audioBackend = other.audioBackend,
      audioVoice = other.audioVoice,
      audioSpeed = other.audioSpeed,
      autoSaveEnabled = other.autoSaveEnabled;
}

@Riverpod(keepAlive: true)
class UserStateNotifier extends _$UserStateNotifier {
  late final Box<UserState> _box;

  @override
  UserState build() {
    final objectbox = ref.watch(objectboxProvider);
    _box = objectbox.store.box<UserState>();
    final userState = _box.get(1);
    if (userState == null) {
      final newUserState = UserState();
      newUserState.highlightColorPalette = [
        '#22f44336',
        '#22ff9800',
        '#22ffeb3b',
        '#224caf50',
        '#2200bcd4',
        '#223f51b5',
      ];
      _box.put(newUserState, mode: PutMode.put);
      return newUserState;
    }
    if (userState.highlightColorPalette.isEmpty) {
      userState.highlightColorPalette = [
        '#22f44336',
        '#22ff9800',
        '#22ffeb3b',
        '#224caf50',
        '#2200bcd4',
        '#223f51b5',
      ];
      _box.put(userState);
    }
    if (userState.highlightColor == null) {
      userState.highlightColor = userState.highlightColorPalette[0];
      _box.put(userState);
    }
    return userState;
  }

  void updateSelectedText(String? text) {
    state = UserState.from(state)..selectedText = text;
  }

  void setAppearance(String appearance) {
    state = UserState.from(state)..appearance = appearance;
    _box.put(state, mode: PutMode.put);
  }

  void setHighlightModeEnabled(bool highlightModeEnabled) {
    state = UserState.from(state)..highlightModeEnabled = highlightModeEnabled;
    _box.put(state, mode: PutMode.put);
  }

  void setHighlightColor(String? highlightColor) {
    state = UserState.from(state)..highlightColor = highlightColor;
    _box.put(state, mode: PutMode.put);
  }

  void setHighlightActiveColorIndex(int index) {
    state = UserState.from(state)
      ..highlightActiveColorIndex = index
      ..highlightColor = state.highlightColorPalette[index];
    _box.put(state, mode: PutMode.put);
  }

  void setPreviousPosition(String? previousPosition) {
    state = UserState.from(state)..previousPosition = previousPosition;
    _box.put(state, mode: PutMode.put);
  }

  void setAudioReader(bool audioReader) {
    state = UserState.from(state)..audioReader = audioReader;
    _box.put(state, mode: PutMode.put);
  }

  void setUseKeyboardShortcutsToPlayPause(
    bool useKeyboardShortcutsToPlayPause,
  ) {
    state = UserState.from(state)
      ..useKeyboardShortcutsToPlayPause = useKeyboardShortcutsToPlayPause;
    _box.put(state, mode: PutMode.put);
  }

  void setCommandClickToReadSentence(bool commandClickToReadSentence) {
    state = UserState.from(state)
      ..commandClickToReadSentence = commandClickToReadSentence;
    _box.put(state, mode: PutMode.put);
  }

  void setAudioBackend(String audioBackend) {
    state = UserState.from(state)..audioBackend = audioBackend;
    _box.put(state, mode: PutMode.put);
  }

  void setAudioVoice(String? audioVoice) {
    state = UserState.from(state)..audioVoice = audioVoice;
    _box.put(state, mode: PutMode.put);
  }

  void setAudioSpeed(double audioSpeed) {
    state = UserState.from(state)..audioSpeed = audioSpeed;
    _box.put(state, mode: PutMode.put);
  }

  void setHighlightColorPalette(List<String> highlightColorPalette) {
    state = UserState.from(state)
      ..highlightColorPalette = highlightColorPalette;
    _box.put(state, mode: PutMode.put);
  }

  void setAutoSaveEnabled(bool autoSaveEnabled) {
    state = UserState.from(state)..autoSaveEnabled = autoSaveEnabled;
    _box.put(state, mode: PutMode.put);
  }

  void nuke() {
    _box.remove(1);
    ref.invalidateSelf();
  }
}
