"""Create an instrumented Dart-only SDK copy; never edit the prepared SDK.

Usage: python3 tool/duration_profile/prepare_sdk.py OUTPUT_DIRECTORY
The new directory must not exist. Native code/model bytes remain unchanged.
"""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

APP = Path(__file__).resolve().parents[2]
SOURCE = APP / '.mlsr/sdk/bindings/dart'


def replace(path, old, new):
    value = path.read_text()
    if value.count(old) != 1:
        raise ValueError(f'Expected exactly one instrumentation site in {path}: {old[:80]}')
    path.write_text(value.replace(old, new))


def main():
    destination = Path(sys.argv[1]).resolve()
    destination.mkdir(parents=True, exist_ok=False)
    sdk = destination / 'sdk'
    shutil.copytree(SOURCE, sdk, ignore=shutil.ignore_patterns('.dart_tool', 'build', '.git'))
    synthesis = sdk / 'lib/src/synthesis.dart'
    native = sdk / 'lib/src/synthesis_native.dart'
    sdk_native = sdk / 'lib/src/sdk_native.dart'
    replace(synthesis, "import 'dart:async';", "import 'dart:async';\nimport 'dart:developer' as developer;\nexport 'synthesis_native.dart' show sdkTimingEnabled, sdkTimingEvents;")
    replace(native, "import 'dart:convert';", "import 'dart:convert';\nimport 'dart:developer' as developer;")
    replace(native, "part 'sdk_native.dart';", """part 'sdk_native.dart';

// Diagnostic copy only. Bounded and text-free; timestamps share Timeline's clock.
bool sdkTimingEnabled = false;
final sdkTimingEvents = <Map<String, Object?>>[];
void recordSdkTiming(Map<String, Object?> event) {
  if (sdkTimingEvents.length >= 100000) throw StateError('SDK timing buffer full');
  sdkTimingEvents.add(event);
}
""")
    replace(synthesis, '      final values = message as List;\n      final completer', '''      final values = message as List;
      if (values.length > 3) {
        recordSdkTiming({...Map<String, Object?>.from(values[3] as Map),
          'delivered_us': developer.Timeline.now});
      }
      final completer''')
    replace(synthesis, '_commands.send([id, operation, args]);', '''_commands.send([id, operation, args,
      if (sdkTimingEnabled) developer.Timeline.now]);''')
    replace(native, '''    final id = values[0] as int;
    try {''', '''    final id = values[0] as int;
    final timing = values.length > 3 ? <String, Object?>{
      'operation': values[1], 'handle': (values[2] as Map)['handle'],
      'request': id, 'lane': 'shared', 'enqueued_us': values[3],
      'started_us': developer.Timeline.now,
    } : null;
    List<Object?> response(Object? result, Object? error) => [id, result, error,
      if (timing != null) {...timing, 'finished_us': developer.Timeline.now}];
    try {''')
    replace(native, 'responses.send([id, result, null]);', 'responses.send(response(result, null));')
    replace(native, 'responses.send([id, null, error.toMessage()]);', 'responses.send(response(null, error.toMessage()));')
    replace(native, '''responses.send([
        id,
        null,
        ['adapter_error', error.toString()],
      ]);''', "responses.send(response(null, ['adapter_error', error.toString()]));")
    replace(sdk_native, ') => Isolate.run(() => sdkNativeOperation(operation, args));', ''') async {
  if (!sdkTimingEnabled) return Isolate.run(() => sdkNativeOperation(operation, args));
  final enqueued = developer.Timeline.now;
  final response = await Isolate.run(() {
    final start = developer.Timeline.now;
    final value = sdkNativeOperation(operation, args);
    return [value, start, developer.Timeline.now];
  });
  recordSdkTiming({'operation': operation, 'handle': args['handle'],
    'lane': 'temporary', 'enqueued_us': enqueued, 'started_us': response[1],
    'finished_us': response[2], 'delivered_us': developer.Timeline.now});
  return response[0];
}''')
    (destination / 'pubspec.yaml').write_text(f'''name: podofo_duration_probe
publish_to: none
environment:
  sdk: '>=3.13.0 <4.0.0'
dependencies:
  mlsr:
    path: sdk
  crypto: ^3.0.7
hooks:
  user_defines:
    mlsr:
      native-library: {json.dumps(str(APP / '.mlsr/native/mlsr_ffi'))}
''')
    shutil.copy2(APP / 'tool/duration_profile/probe.dart.in', destination / 'probe.dart')
    files = ['lib/src/synthesis.dart', 'lib/src/synthesis_native.dart', 'lib/src/sdk_native.dart']
    (destination / 'instrumentation.json').write_text(json.dumps({
        'sdk_revision': subprocess.check_output(['git', '-C', str(SOURCE), 'rev-parse', 'HEAD'], text=True).strip(),
        'native_sha256': hashlib.sha256((APP / '.mlsr/native/mlsr_ffi').read_bytes()).hexdigest(),
        'files': {name: {'original': hashlib.sha256((SOURCE / name).read_bytes()).hexdigest(),
                         'instrumented': hashlib.sha256((sdk / name).read_bytes()).hexdigest()} for name in files},
    }, indent=2) + '\n')
    print(destination)


if __name__ == '__main__':
    main()
