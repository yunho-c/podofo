import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/src/widgets/interactive_viewer.dart' as pdf;

void main() {
  for (final kind in [PointerDeviceKind.mouse, PointerDeviceKind.touch]) {
    testWidgets('PDF pan still accepts primary $kind drags', (tester) async {
      final controller = TransformationController();
      addTearDown(controller.dispose);
      await _mount(tester, controller);
      final initial = controller.value.clone();
      final pointer = await tester.startGesture(
        tester.getCenter(find.byType(pdf.InteractiveViewer)),
        kind: kind,
      );
      await pointer.moveBy(const Offset(-50, 0));
      await pointer.moveBy(const Offset(-50, 0));
      await tester.pump();
      expect(
        controller.value.getTranslation().x,
        lessThan(initial.getTranslation().x),
      );
      expect(controller.value.getMaxScaleOnAxis(), initial.getMaxScaleOnAxis());
      await pointer.up();
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('PDF zoom still accepts two-finger touch pinches', (
    tester,
  ) async {
    final controller = TransformationController();
    addTearDown(controller.dispose);
    await _mount(tester, controller);
    final center = tester.getCenter(find.byType(pdf.InteractiveViewer));
    final left = await tester.startGesture(center - const Offset(40, 0));
    final right = await tester.startGesture(center + const Offset(40, 0));
    await left.moveBy(const Offset(-40, 0));
    await right.moveBy(const Offset(40, 0));
    await tester.pump();
    expect(controller.value.getMaxScaleOnAxis(), greaterThan(1));
    await left.up();
    await right.up();
    await tester.pumpWidget(const SizedBox());
  });
}

Future<void> _mount(WidgetTester tester, TransformationController controller) =>
    tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 400,
            height: 400,
            child: pdf.InteractiveViewer(
              transformationController: controller,
              constrained: false,
              boundaryMargin: const EdgeInsets.all(1000),
              child: const SizedBox(width: 1000, height: 1000),
            ),
          ),
        ),
      ),
    );
