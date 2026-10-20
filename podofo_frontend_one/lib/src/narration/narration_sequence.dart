import 'source_map.dart';

abstract interface class NarrationSequence {
  Future<NarrationPassage?> move(int direction);
  void cancelPending();
  void close();
}
