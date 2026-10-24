/// Opt-in, bounded wall-time observations. No text or audio is retained.
/// Parent spans overlap their children and must not be added to them.
class DurationProfile {
  DurationProfile({this.limit = 20000});
  final int limit;
  final _clock = Stopwatch()..start();
  final events = <Map<String, Object?>>[];
  int dropped = 0;

  int begin() => _clock.elapsedMicroseconds;

  void end(String stage, int start, [Map<String, Object?> fields = const {}]) {
    final finish = _clock.elapsedMicroseconds;
    if (events.length >= limit) {
      dropped++;
      return;
    }
    events.add({
      'stage': stage,
      'start_us': start,
      'elapsed_us': finish - start,
      ...fields,
    });
  }

  Map<String, Object?> toJson() => {
    'clock': 'monotonic microseconds relative to profile creation',
    'overlap': 'document and passage spans contain their child spans',
    'dropped': dropped,
    'events': events,
  };
}
