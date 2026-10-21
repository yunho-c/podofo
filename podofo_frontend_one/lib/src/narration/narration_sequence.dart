import 'source_map.dart';

abstract interface class NarrationSequence {
  Future<NarrationPassage?> move(int direction);
  Future<void> prepareNext();
  void cancelPending();
  void close();
}
