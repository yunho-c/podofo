import 'package:shadcn_flutter/shadcn_flutter.dart';

class StudyPane extends StatelessWidget {
  const StudyPane({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 5.0,
        children: [
          // const SizedBox(height: 16),
          // Button.card(child: const Text('Study Pane')),
          // const SizedBox(height: 16),
          Button(
            alignment: AlignmentGeometry.topLeft,
            enabled: true,
            style: ButtonStyle.outline(size: ButtonSize.large),
            onTapDown: (details) => {},
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Summarize').x2Large,
                // const Text('Create an executive summary').small,
              ],
            ),
          ),
          Button(
            alignment: AlignmentGeometry.topLeft,
            enabled: true,
            style: ButtonStyle.outline(size: ButtonSize.large),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('FAQ').x2Large,
                const Text('with answer keys').small,
              ],
            ),
          ),
          Button(
            alignment: AlignmentGeometry.topLeft,
            enabled: true,
            style: ButtonStyle.outline(size: ButtonSize.large),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Quiz Mode').x2Large,
                // const Text('Enter Quiz Mode').small,
              ],
            ),
          ),
          Button(
            alignment: AlignmentGeometry.topLeft,
            enabled: true,
            style: ButtonStyle.outline(size: ButtonSize.large),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Anki').x2Large,
                // const Text('Generate flashcards').small,
              ],
            ),
          ),

          // Button(
          //   style: ButtonStyle.outline(size: ButtonSize.large),
          //   child: const Text('Summary'),
          // ),
          // Button(
          //   style: ButtonStyle.primary(size: ButtonSize.xLarge),
          //   child: const Text('Study Pane'),
          // ),
        ],
      ),
    );
  }
}
