import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:podofo_one/src/services/windows_title_bar.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('podofo/windows_title_bar');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  test(
    'native caption follows brightness changes without repeated calls',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'initialize') {
          return {'height': 34.0, 'buttonsWidth': 140.0};
        }
        return null;
      });
      final titleBar = WindowsTitleBar();
      addTearDown(() {
        channel.setMethodCallHandler(null);
        messenger.setMockMethodCallHandler(channel, null);
        titleBar.dispose();
      });
      await titleBar.setBrightness(Brightness.dark);
      expect(calls, isEmpty);
      await titleBar.initialize();
      expect(titleBar.value.native, isTrue);
      expect(titleBar.value.height, 34);
      await titleBar.setBrightness(Brightness.dark);
      await titleBar.setBrightness(Brightness.dark);
      await titleBar.setBrightness(Brightness.light);
      expect(calls.map((call) => call.method), [
        'initialize',
        'setBrightness',
        'setBrightness',
      ]);
      expect(calls.skip(1).map((call) => call.arguments), [true, false]);

      await messenger.handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(
          const MethodCall('metricsChanged', {
            'height': 32.0,
            'buttonsWidth': 138.0,
          }),
        ),
        (_) {},
      );
      expect(titleBar.value.height, 32);
      expect(titleBar.value.buttonsWidth, 138);
    },
    skip: !Platform.isWindows,
  );
}
