import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final contextMenuTraceProvider = Provider<ContextMenuTrace>((ref) {
  final trace = ContextMenuTrace();
  ref.onDispose(trace.dispose);
  return trace;
});

/// Opt-in, bounded diagnostics. Notifications are deferred so recording from a
/// menu build cannot rebuild the Debug pane during that same build.
class ContextMenuTrace extends ChangeNotifier {
  static const capacity = 400;
  final _lines = Queue<String>();
  final _pointers = <int, ContextMenuTraceClick>{};
  final _clock = Stopwatch()..start();
  bool _enabled = false, _disposed = false, _notificationPending = false;
  int _nextId = 0, _generation = 0, dropped = 0;
  DateTime _started = DateTime.now().toUtc();
  bool get enabled => _enabled;
  int get length => _lines.length;

  set enabled(bool value) {
    if (_disposed || value == _enabled) return;
    _enabled = value;
    if (value) {
      GestureBinding.instance.pointerRouter.addGlobalRoute(_pointerEvent);
    } else {
      GestureBinding.instance.pointerRouter.removeGlobalRoute(_pointerEvent);
      _pointers.clear();
      _generation++;
    }
    _notifyLater();
  }

  ContextMenuTraceClick? begin(PointerDownEvent event) {
    if (!_enabled || event.buttons & kSecondaryMouseButton == 0) return null;
    if (_pointers[event.pointer]?.released == true) {
      _pointers.remove(event.pointer);
    }
    return _pointers.putIfAbsent(event.pointer, () {
      final click = ContextMenuTraceClick._(
        this,
        ++_nextId,
        _generation,
        event.position,
      )..lastButtons = event.buttons;
      click.record('pointer.down', {
        'pointer': event.pointer,
        'kind': event.kind.name,
        'buttons': event.buttons,
        'x': event.position.dx,
        'y': event.position.dy,
      });
      // Mouse pointer IDs can accumulate across clicks; keep only recent ones.
      if (_pointers.length >= 32) _pointers.remove(_pointers.keys.first);
      return click;
    });
  }

  void _pointerEvent(PointerEvent event) {
    if (event is PointerDownEvent) {
      begin(event);
      return;
    }
    final click = _pointers[event.pointer];
    if (click == null || click.released) return;
    final distance = (event.position - click.origin).distance;
    if (distance > click.maxMovement) click.maxMovement = distance;
    if (event is PointerMoveEvent) {
      if (click.lastButtons != event.buttons) {
        click.lastButtons = event.buttons;
        click.record('pointer.buttons', {'buttons': event.buttons});
      }
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      click.released = true;
      click.record(event is PointerUpEvent ? 'pointer.up' : 'pointer.cancel', {
        'buttons': event.buttons,
        'maxMovement': click.maxMovement,
        'x': event.position.dx,
        'y': event.position.dy,
      });
    }
  }

  void _record(
    ContextMenuTraceClick click,
    String event,
    Map<String, Object?> fields,
  ) {
    if (!_enabled || _disposed || click.generation != _generation) return;
    final signature = jsonEncode({'event': event, ...fields});
    if (click.lastEvent == signature) return;
    click.lastEvent = signature;
    _lines.add(
      jsonEncode({
        'ms': _clock.elapsedMicroseconds / 1000,
        'click': click.id,
        'event': event,
        ...fields,
      }),
    );
    if (_lines.length > capacity) {
      _lines.removeFirst();
      dropped++;
    }
    _notifyLater();
  }

  String export() => [
    jsonEncode({
      'trace': 'podofo-context-menu-v1',
      'startedUtc': _started.toIso8601String(),
      'platform': defaultTargetPlatform.name,
      'dropped': dropped,
    }),
    ..._lines,
  ].join('\n');

  void clear() {
    _lines.clear();
    _pointers.clear();
    _generation++;
    dropped = 0;
    _started = DateTime.now().toUtc();
    _clock.reset();
    _notifyLater();
  }

  void _notifyLater() {
    if (_notificationPending || _disposed) return;
    _notificationPending = true;
    scheduleMicrotask(() {
      _notificationPending = false;
      if (!_disposed) notifyListeners();
    });
  }

  @override
  void dispose() {
    if (_enabled) {
      GestureBinding.instance.pointerRouter.removeGlobalRoute(_pointerEvent);
    }
    _disposed = true;
    _pointers.clear();
    super.dispose();
  }
}

class ContextMenuTraceClick {
  ContextMenuTraceClick._(this.trace, this.id, this.generation, this.origin);
  final ContextMenuTrace trace;
  final int id, generation;
  final Offset origin;
  double maxMovement = 0;
  bool released = false;
  int? lastButtons;
  String? lastEvent;
  void record(String event, [Map<String, Object?> fields = const {}]) =>
      trace._record(this, event, fields);
}
