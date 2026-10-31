import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'package:podofo_one/src/providers/user_state_provider.dart';
import 'package:podofo_one/src/services/context_menu_trace.dart';
import 'package:podofo_one/src/widgets/panes/debug_pane.dart';

List<Map<String, dynamic>> events(ContextMenuTrace trace) => trace
    .export()
    .split('\n')
    .skip(1)
    .map((s) => jsonDecode(s) as Map<String, dynamic>)
    .toList();

class _Preferences extends UserStateNotifier {
  @override
  UserState build() => UserState();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'trace observes global secondary pointers and stops when disabled',
    (tester) async {
      final trace = ContextMenuTrace();
      addTearDown(trace.dispose);
      final mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await mouse.down(const Offset(10, 10));
      await mouse.up();
      expect(trace.length, 0);
      trace.enabled = true;
      await mouse.down(const Offset(10, 10));
      await mouse.moveTo(const Offset(40, 50));
      await mouse.up();
      final captured = events(trace);
      expect(captured.map((e) => e['event']), ['pointer.down', 'pointer.up']);
      expect(captured.last['maxMovement'], 50);
      expect(captured.map((e) => e['click']).toSet(), hasLength(1));
      trace.enabled = false;
      await mouse.down(const Offset(20, 20));
      await mouse.up();
      expect(events(trace), captured);
    },
  );

  test('trace is bounded and ignores late results after clear or disable', () {
    final trace = ContextMenuTrace()..enabled = true;
    addTearDown(trace.dispose);
    final click = trace.begin(
      const PointerDownEvent(pointer: 1, buttons: kSecondaryMouseButton),
    )!;
    expect(
      trace.begin(
        const PointerDownEvent(pointer: 1, buttons: kSecondaryMouseButton),
      ),
      same(click),
    );
    for (var i = 0; i < 450; i++) {
      click.record('menu.build', {'sequence': i});
    }
    expect(trace.length, ContextMenuTrace.capacity);
    expect(trace.dropped, 51);
    trace.clear();
    click.record('late');
    expect(trace.length, 0);
    final next = trace.begin(
      const PointerDownEvent(pointer: 2, buttons: kSecondaryMouseButton),
    )!;
    trace.enabled = false;
    next.record('late');
    expect(trace.length, 1);
  });

  testWidgets('Debug pane toggles, copies and clears the trace', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [userStateNotifierProvider.overrideWith(_Preferences.new)],
    );
    addTearDown(container.dispose);
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const ShadcnApp(home: SizedBox(width: 250, child: DebugPane())),
      ),
    );
    await tester.tap(find.byType(Switch).last);
    await tester.pump();
    final trace = container.read(contextMenuTraceProvider);
    expect(trace.enabled, true);
    trace
        .begin(
          const PointerDownEvent(pointer: 7, buttons: kSecondaryMouseButton),
        )!
        .record('test');
    await tester.pump();
    await tester.ensureVisible(find.text('Copy trace'));
    await tester.tap(find.text('Copy trace'));
    await tester.pump();
    expect(copied, contains('podofo-context-menu-v1'));
    expect(copied, contains('"event":"test"'));
    await tester.tap(find.text('Clear trace'));
    await tester.pump();
    expect(trace.length, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
