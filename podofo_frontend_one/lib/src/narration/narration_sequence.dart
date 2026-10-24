import 'source_map.dart';

abstract interface class NarrationSequence {
  Future<NarrationPassage?> move(int direction);
  Future<void> prepareNext();
  void cancelPending();
  void close();
}

/// Optional text-only preparation, independent of playback position and pause.
abstract interface class DocumentIndexingSequence {
  Future<void> indexDocument({bool retryFailures = false});
}
