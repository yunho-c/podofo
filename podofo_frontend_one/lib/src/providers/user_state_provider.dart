import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:objectbox/objectbox.dart';
// import 'package:podofo_one/src/data/objectbox.dart';
import 'package:podofo_one/src/providers/providers.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'user_state_provider.g.dart';

@Entity()
class UserState {
  @Id()
  int id = 0;

  String appearance = 'light';
  bool highlight = false;
  String? highlightColor;
  String? previousPosition;

  UserState();
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
      _box.put(newUserState, mode: PutMode.put);
      return newUserState;
    }
    return userState;
  }

  void setAppearance(String appearance) {
    state = state..appearance = appearance;
    _box.put(state, mode: PutMode.put);
  }

  void setHighlight(bool highlight) {
    state = state..highlight = highlight;
    _box.put(state, mode: PutMode.put);
  }

  void setHighlightColor(String? highlightColor) {
    state = state..highlightColor = highlightColor;
    _box.put(state, mode: PutMode.put);
  }

  void setPreviousPosition(String? previousPosition) {
    state = state..previousPosition = previousPosition;
    _box.put(state, mode: PutMode.put);
  }
}
