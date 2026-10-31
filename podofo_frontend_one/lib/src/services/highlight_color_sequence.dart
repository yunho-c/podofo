import 'pdf_session.dart';

/// Serializes number-key choices after an asynchronous highlight creation.
/// Cancellation drops queued choices; an edit already applying may finish.
class HighlightColorSequence {
  HighlightColorSequence({required this.recolor, required this.onError});

  final Future<HighlightTarget?> Function(
    HighlightTarget target,
    int color,
    bool Function() isActive,
  )
  recolor;
  final void Function(Object error) onError;
  int _generation = 0;
  Future<HighlightTarget?>? _tail;

  bool get active => _tail != null;

  void cancel() {
    _generation++;
    _tail = null;
  }

  void start(Future<HighlightTarget?> Function() create) {
    cancel();
    _tail = _run(create, _generation);
  }

  bool choose(int color) {
    final previous = _tail;
    if (previous == null) return false;
    final generation = _generation;
    _tail = _run(() async {
      final target = await previous;
      bool isActive() =>
          generation == _generation && target != null && target.isCurrent;
      if (!isActive()) return null;
      return recolor(target!, color, isActive);
    }, generation);
    return true;
  }

  Future<HighlightTarget?> _run(
    Future<HighlightTarget?> Function() action,
    int generation,
  ) async {
    try {
      final target = await Future.sync(action);
      if (generation != _generation) return null;
      if (target == null || !target.isCurrent) {
        cancel();
        return null;
      }
      return target;
    } catch (error) {
      if (generation == _generation) {
        cancel();
        onError(error);
      }
      return null;
    }
  }

  Future<void> waitForIdle() async => await _tail;
}
